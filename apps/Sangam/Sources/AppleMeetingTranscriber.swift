#if os(macOS) || os(iOS)
  import Foundation
  import JitsiConference
  import JitsiMedia
  @preconcurrency import AVFoundation
  import Speech

  /// Only copies cross the capture boundary. The producer never mutates a
  /// buffer after yielding it; conversion and Speech work run on SpeechStream.
  nonisolated private struct MicrophonePacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let time: TimeInterval
  }

  @available(macOS 26, iOS 26, *)
  @MainActor
  final class AppleMeetingTranscriber {
    struct Result: Sendable {
      let streamID: String
      let participantID: String
      let start: TimeInterval
      let end: TimeInterval
      let text: String
      let isFinal: Bool
    }

    private struct RemoteWorker {
      let generation: UUID
      let tap: RemoteAudioTap
      let speech: SpeechStream
      let pump: Task<Void, Never>
      let acceptAfter: TimeInterval
    }

    private let locale: Locale
    private let origin: TimeInterval
    private let result: @MainActor @Sendable (Result) -> Void
    private let report: @MainActor @Sendable (String) -> Void
    private var workers: [String: RemoteWorker] = [:]
    private var pending: [String: UUID] = [:]
    private var desired: [String: UUID] = [:]
    private var microphone: AVAudioEngine?
    private var microphonePump: Task<Void, Never>?
    private var microphoneSpeech: SpeechStream?
    private var running = true
    private var localEpoch = UUID()
    private var retired: [UUID: Task<Void, Never>] = [:]
    private var retiredSpeech: [UUID: SpeechStream] = [:]

    init(
      locale: Locale, origin: TimeInterval,
      result: @escaping @MainActor @Sendable (Result) -> Void,
      report: @escaping @MainActor @Sendable (String) -> Void
    ) {
      self.locale = locale
      self.origin = origin
      self.result = result
      self.report = report
    }

    static func prepare(locale: Locale) async throws -> Locale {
      guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
      guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
        throw TranscriptionError.language
      }
      let module = SpeechTranscriber(
        locale: supported, preset: .timeIndexedProgressiveTranscription)
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        try await request.downloadAndInstall()
      }
      return supported
    }

    func setRemoteStreams(_ streams: [RemoteAudioStream]) async {
      guard running else { return }
      desired = Dictionary(uniqueKeysWithValues: streams.map { ($0.id, $0.generation) })
      let current = Set(streams.map(\.id))
      for id in Array(workers.keys) where !current.contains(id) { remove(id) }
      for id in Array(pending.keys) where !current.contains(id) { pending.removeValue(forKey: id) }
      for stream in streams {
        guard desired[stream.id] == stream.generation else { continue }
        guard workers[stream.id]?.generation != stream.generation,
          pending[stream.id] != stream.generation
        else { continue }
        let remapped = workers[stream.id] != nil
        remove(stream.id, drainTail: !remapped)
        // Keep the number of live recognizers bounded even on Macs that let
        // Speech allocate indefinitely. Additional streams are reported.
        guard workers.count + pending.count < 8 else {
          report("Transcription is limited to eight remote audio streams on this device.")
          continue
        }
        pending[stream.id] = stream.generation
        do {
          let speech = try await SpeechStream.create(
            locale: locale, origin: origin,
            streamID: stream.generation.uuidString, participantID: stream.endpointID,
            result: result, report: report)
          guard running, desired[stream.id] == stream.generation,
            pending[stream.id] == stream.generation
          else {
            await speech.cancel()
            continue
          }
          pending.removeValue(forKey: stream.id)
          guard let tap = stream.track.makeTap() else {
            await speech.cancel()
            report("This WebRTC audio source cannot be transcribed.")
            continue
          }
          // Audio buffered by WebRTC at a slot remap has no source timestamp
          // in M124. Discard the boundary instead of giving it the new name.
          let acceptAfter = ProcessInfo.processInfo.systemUptime + (remapped ? 1 : 0)
          if remapped {
            report("An audio source changed; a short boundary may be missing from the transcript.")
          }
          let pump = Task.detached(priority: .utility) { [report] in
            while !Task.isCancelled {
              for frame in tap.drain() where frame.startTime >= acceptAfter {
                if frame.discontinuity {
                  await report("Audio processing fell behind; the transcript has a gap.")
                }
                await speech.push(frame)
              }
              do { try await Task.sleep(for: .milliseconds(40)) } catch { break }
            }
          }
          workers[stream.id] = RemoteWorker(
            generation: stream.generation, tap: tap, speech: speech, pump: pump,
            acceptAfter: acceptAfter)
        } catch {
          pending.removeValue(forKey: stream.id)
          report("Transcription could not start for one speaker: \(error.localizedDescription)")
        }
      }
    }

    private func remove(_ id: String, drainTail: Bool = true) {
      pending.removeValue(forKey: id)
      guard let worker = workers.removeValue(forKey: id) else { return }
      worker.pump.cancel()
      let retirement = UUID()
      retiredSpeech[retirement] = worker.speech
      retired[retirement] = Task { [weak self] in
        await worker.pump.value
        // Drain the final buffered samples before detaching the native sink.
        let tail = worker.tap.drain()
        if drainTail {
          for frame in tail where frame.startTime >= worker.acceptAfter {
            await worker.speech.push(frame)
          }
        }
        worker.tap.stop()
        await worker.speech.finish()
        self?.retired.removeValue(forKey: retirement)
        self?.retiredSpeech.removeValue(forKey: retirement)
      }
    }

    /// Starts or stops transcribing the local microphone.
    ///
    /// Both platforms now, by the same route: WebRTC's own microphone source
    /// cannot be tapped (its local track implements no audio sink), so this
    /// opens a second input beside the call and never touches WebRTC's
    /// outgoing track. On iOS that second input shares the audio session
    /// CallKit and WebRTC already own, which is the part that needs real
    /// device testing — the session is left exactly as the call configured
    /// it, and a failure here is reported rather than thrown at the call.
    func setLocalMuted(_ muted: Bool) async {
      localEpoch = UUID()
      let epoch = localEpoch
      await stopMicrophone()
      guard running, !muted, epoch == localEpoch else { return }
      do {
        let speech = try await SpeechStream.create(
          locale: locale, origin: origin,
          streamID: "local-\(epoch)", participantID: "local", result: result, report: report)
        guard running, epoch == localEpoch else {
          await speech.cancel()
          return
        }
        let engine = AVAudioEngine()
        // Torn down immediately when muted, on either platform.
        #if os(macOS)
          // Apple's voice processing keeps the room's own audio, played back
          // through the speakers, out of what is transcribed as your voice.
          try engine.inputNode.setVoiceProcessingEnabled(true)
        #else
          // Not on iOS: the call has the session in .voiceChat already, so
          // this input arrives echo-cancelled by the system's own unit, and
          // asking for voice processing here would stand a second one up
          // beside WebRTC's.
        #endif
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
          throw TranscriptionError.microphone
        }
        let stream = AsyncStream<MicrophonePacket>.makeStream(
          bufferingPolicy: .bufferingNewest(32))
        let continuation = stream.continuation
        // AVFoundation invokes this on its audio queue. The SDK's non-Sendable
        // tap block otherwise inherits MainActor here and traps on the first
        // buffer. Capture only the thread-safe continuation and copy the audio
        // before returning; the framework owns and reuses the input buffer.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) {
          @Sendable [continuation] buffer, time in
          guard let copy = Self.captureCopy(of: buffer) else { return }
          let start =
            time.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: time.hostTime)
            : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength)
              / buffer.format.sampleRate
          continuation.yield(MicrophonePacket(buffer: copy, time: start))
        }
        do { try engine.start() } catch {
          engine.inputNode.removeTap(onBus: 0)
          await speech.cancel()
          throw error
        }
        microphone = engine
        microphoneSpeech = speech
        microphonePump = Task.detached(priority: .utility) {
          for await packet in stream.stream {
            guard !Task.isCancelled else { break }
            await speech.push(packet.buffer, at: packet.time)
          }
        }
      } catch {
        report("Your microphone could not be transcribed: \(error.localizedDescription)")
      }
    }

    /// A private copy of a capture buffer for the transcription path: the
    /// framework owns and reuses the one it hands the tap.
    ///
    /// Multi-channel captures are narrowed to their first channel here.
    /// Voice processing presents its output as a discrete multi-channel
    /// stream — the same processed audio on every channel on this hardware —
    /// and AVAudioConverter has no downmix for a discrete layout: it accepts
    /// the conversion to the recognizer's mono format, returns the right
    /// number of frames, and fills every one of them with silence. Taking a
    /// single channel is what keeps the microphone audible to recognition.
    nonisolated static func captureCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
      if buffer.format.channelCount > 1, let source = buffer.floatChannelData,
        let mono = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
          channels: 1, interleaved: false),
        let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
        let destination = copy.floatChannelData
      {
        copy.frameLength = buffer.frameLength
        destination[0].update(from: source[0], count: Int(buffer.frameLength))
        return copy
      }
      guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
      else { return nil }
      copy.frameLength = buffer.frameLength
      let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
      let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
      for index in source.indices {
        if let from = source[index].mData, let to = destination[index].mData {
          memcpy(to, from, Int(source[index].mDataByteSize))
        }
      }
      return copy
    }

    private func stopMicrophone() async {
      microphone?.stop()
      microphone?.inputNode.removeTap(onBus: 0)
      microphone = nil
      let pump = microphonePump
      let speech = microphoneSpeech
      microphonePump = nil
      microphoneSpeech = nil
      pump?.cancel()
      await pump?.value
      await speech?.finish()
    }

    func finish() async {
      running = false
      localEpoch = UUID()
      pending.removeAll()
      desired.removeAll()
      for id in Array(workers.keys) { remove(id) }
      await stopMicrophone()
      for task in Array(retired.values) { await task.value }
      retired.removeAll()
      retiredSpeech.removeAll()
    }

    func cancel() async {
      running = false
      localEpoch = UUID()
      pending.removeAll()
      desired.removeAll()
      microphone?.stop()
      microphone?.inputNode.removeTap(onBus: 0)
      microphone = nil
      microphonePump?.cancel()
      microphonePump = nil
      let local = microphoneSpeech
      microphoneSpeech = nil
      let current = Array(workers.values)
      workers.removeAll()
      for worker in current {
        worker.pump.cancel()
        worker.tap.stop()
      }
      await local?.cancel()
      for worker in current { await worker.speech.cancel() }
      for task in retired.values { task.cancel() }
      let finishing = Array(retiredSpeech.values)
      retired.removeAll()
      retiredSpeech.removeAll()
      for speech in finishing { await speech.cancel() }
    }

    enum TranscriptionError: LocalizedError {
      case unavailable, language, microphone
      var errorDescription: String? {
        switch self {
        case .unavailable: "On-device transcription is unavailable on this device."
        case .language: "Apple does not support the selected transcription language on this device."
        case .microphone: "No microphone audio format is available."
        }
      }
    }

    #if DEBUG && os(macOS)
      /// Checks the local microphone path without a meeting and reports what
      /// happened rather than what was said: whether this process receives
      /// microphone audio at all, whether it still arrives through Apple's
      /// voice processing — which is the path a call uses — and how much text
      /// recognition made of it. The documented way to check a headset, a
      /// Bluetooth switch or Voice Isolation, and the way to tell a dead
      /// capture apart from a dead recognizer.
      static func runMicrophoneCheck(seconds: Double) async -> Bool {
        var lines = ["Microphone check — \(seconds)s per stage, nothing written to disk."]
        let plain = probeInput(voiceProcessed: false, for: 2)
        let processed = probeInput(voiceProcessed: true, for: 2)
        lines.append(
          String(
            format: "clocks:                audio host %.3f s, meeting %.3f s",
            AVAudioTime.seconds(forHostTime: mach_absolute_time()),
            ProcessInfo.processInfo.systemUptime))
        lines.append("plain input:           " + plain.summary)
        lines.append("voice-processed input: " + processed.summary)

        let collected = CheckResults()
        let origin = ProcessInfo.processInfo.systemUptime
        let transcriber: AppleMeetingTranscriber
        do {
          let locale = try await prepare(locale: Locale.current)
          lines.append("language:              \(locale.identifier)")
          // Recognition takes one format only. If the capture format cannot
          // be converted into it, every buffer is dropped without a sound.
          let module = SpeechTranscriber(
            locale: locale, preset: .timeIndexedProgressiveTranscription)
          let speechFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
          lines.append(
            "speech wants:          "
              + (speechFormat.map {
                "\(Int($0.sampleRate)) Hz, \($0.channelCount) ch, \($0.commonFormat.rawValue)"
              } ?? "no format available"))
          if let speechFormat {
            for (name, format) in [("plain", plain.format), ("captured", processed.format)] {
              guard let format else { continue }
              lines.append(
                "convert \(name):       " + conversionCheck(from: format, to: speechFormat))
            }
          }
          transcriber = AppleMeetingTranscriber(locale: locale, origin: origin) { result in
            collected.add(result)
          } report: { message in
            collected.note(message)
          }
        } catch {
          lines.append("prepare failed:        \(error.localizedDescription)")
          FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
          return false
        }
        // Exactly what a call does when the microphone is live.
        await transcriber.setLocalMuted(false)
        try? await Task.sleep(for: .seconds(seconds))
        await transcriber.finish()
        lines.append("recognition:           " + collected.summary)
        for note in collected.notes { lines.append("reported:              " + note) }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return collected.heardSomething
      }

      /// Opens the input the way the transcriber does and reports whether
      /// buffers arrive and how loud they are, with voice processing on or
      /// off. Blocks on the run loop rather than the actor so a failure to
      /// deliver buffers is visible as silence, not as a hang.
      private static func probeInput(
        voiceProcessed: Bool, for seconds: Double
      ) -> (summary: String, format: AVAudioFormat?) {
        let engine = AVAudioEngine()
        do {
          try engine.inputNode.setVoiceProcessingEnabled(voiceProcessed)
        } catch {
          return ("voice processing could not be enabled: \(error.localizedDescription)", nil)
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
          return ("no input format (\(format.sampleRate) Hz, \(format.channelCount) ch)", nil)
        }
        let meter = InputMeter()
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) {
          @Sendable [meter] buffer, _ in meter.add(buffer)
        }
        defer {
          engine.stop()
          engine.inputNode.removeTap(onBus: 0)
        }
        do { try engine.start() } catch {
          return ("engine would not start: \(error.localizedDescription)", format)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let (buffers, frames, peak, channelPeaks) = meter.snapshot()
        let layout = format.channelLayout.map { "layout \($0.layoutTag)" } ?? "no layout"
        let perChannel = channelPeaks.map { String(format: "%.4f", $0) }.joined(separator: " ")
        return (
          String(
            format: "%@ Hz, %d ch (%@) — %d buffers, %d frames, peak %.4f [%@]",
            "\(Int(format.sampleRate))", format.channelCount, layout, buffers, frames, peak,
            perChannel),
          format
        )
      }

      /// Runs the conversion that feeds recognition — capture format down to
      /// the one Speech accepts — over a known tone in the first channel, and
      /// reports how much of it survives. Silence here is how a call can look
      /// like it is transcribing and produce nothing.
      private static func conversionCheck(from source: AVAudioFormat, to speech: AVAudioFormat)
        -> String
      {
        guard AVAudioConverter(from: source, to: speech) != nil else {
          return "no converter — audio would be dropped"
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800),
          let channels = input.floatChannelData
        else { return "capture format is not float; not probed" }
        input.frameLength = input.frameCapacity
        for channel in 0..<Int(source.channelCount) {
          channels[channel].update(repeating: 0, count: Int(input.frameLength))
        }
        for frame in 0..<Int(input.frameLength) {
          channels[0][frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(source.sampleRate))
        }
        // Whatever the app does to a capture buffer, the probe does too.
        let prepared = captureCopy(of: input) ?? input
        guard let converter = AVAudioConverter(from: prepared.format, to: speech) else {
          return "no converter for the prepared buffer"
        }
        guard
          let output = AVAudioPCMBuffer(
            pcmFormat: speech,
            frameCapacity: AVAudioFrameCount(
              ceil(Double(prepared.frameLength) * speech.sampleRate / prepared.format.sampleRate))
              + 32)
        else { return "no output buffer" }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
          if consumed {
            status.pointee = .noDataNow
            return nil
          }
          consumed = true
          status.pointee = .haveData
          return prepared
        }
        if let error { return "failed: \(error.localizedDescription)" }
        var peak: Float = 0
        if let samples = output.int16ChannelData {
          for frame in 0..<Int(output.frameLength) {
            peak = max(peak, abs(Float(samples[0][frame])) / 32768)
          }
        } else if let samples = output.floatChannelData {
          for frame in 0..<Int(output.frameLength) { peak = max(peak, abs(samples[0][frame])) }
        }
        return String(
          format: "%d frames out, 0.500 in → %.4f out%@", output.frameLength, peak,
          peak < 0.01 ? "  ← AUDIO LOST" : "")
      }

      /// Counts what recognition produced without keeping what was said.
      @MainActor
      private final class CheckResults {
        private(set) var notes: [String] = []
        private var results = 0
        private var finals = 0
        private var words = 0
        var heardSomething: Bool { finals > 0 && words > 0 }
        var summary: String {
          "\(results) results, \(finals) final, \(words) words recognized"
        }
        func add(_ result: Result) {
          results += 1
          if result.isFinal {
            finals += 1
            words += result.text.split(whereSeparator: \.isWhitespace).count
          }
        }
        func note(_ message: String) { notes.append(message) }
      }

      /// The tap runs on AVFoundation's audio queue; the counters it feeds
      /// are read from the main thread once the probe is over.
      nonisolated private final class InputMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers = 0
        private var frames = 0
        private var peak: Float = 0
        private var channelPeaks: [Float] = []

        func add(_ buffer: AVAudioPCMBuffer) {
          var loudest = [Float](repeating: 0, count: Int(buffer.format.channelCount))
          if let channels = buffer.floatChannelData {
            for channel in loudest.indices {
              let samples = channels[channel]
              for frame in 0..<Int(buffer.frameLength) {
                loudest[channel] = max(loudest[channel], abs(samples[frame]))
              }
            }
          }
          lock.withLock {
            buffers += 1
            frames += Int(buffer.frameLength)
            peak = max(peak, loudest.max() ?? 0)
            if channelPeaks.count < loudest.count {
              channelPeaks += [Float](repeating: 0, count: loudest.count - channelPeaks.count)
            }
            for index in loudest.indices {
              channelPeaks[index] = max(channelPeaks[index], loudest[index])
            }
          }
        }

        func snapshot() -> (Int, Int, Float, [Float]) {
          lock.withLock { (buffers, frames, peak, channelPeaks) }
        }
      }

      /// Feeds generated test speech through the same conversion, recognition,
      /// timestamp and finalization path without opening the microphone.
      static func transcribeFixture(
        _ url: URL, participantID: String, offset: Double,
        result: @escaping @MainActor @Sendable (Result) -> Void,
        report: @escaping @MainActor @Sendable (String) -> Void
      ) async throws {
        let locale = try await prepare(locale: Locale(identifier: "en-US"))
        let worker = try await SpeechStream.create(
          locale: locale, origin: 0,
          streamID: UUID().uuidString, participantID: participantID, result: result, report: report)
        let file = try AVAudioFile(forReading: url)
        while file.framePosition < file.length {
          let position = file.framePosition
          guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
          else { break }
          try file.read(into: buffer)
          await worker.push(
            buffer, at: offset + Double(position) / file.processingFormat.sampleRate)
          try await Task.sleep(for: .milliseconds(70))
        }
        await worker.finish()
      }
    #endif
  }

  @available(macOS 26, iOS 26, *)
  private actor SpeechStream {
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let origin: TimeInterval
    private let report: @MainActor @Sendable (String) -> Void
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var ended = false
    private var previousEnd: CMTime?

    private init(
      analyzer: SpeechAnalyzer, format: AVAudioFormat,
      input: AsyncStream<AnalyzerInput>.Continuation, origin: TimeInterval,
      report: @escaping @MainActor @Sendable (String) -> Void
    ) {
      self.analyzer = analyzer
      self.format = format
      self.input = input
      self.origin = origin
      self.report = report
    }

    static func create(
      locale: Locale, origin: TimeInterval, streamID: String, participantID: String,
      result: @escaping @MainActor @Sendable (AppleMeetingTranscriber.Result) -> Void,
      report: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> SpeechStream {
      let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
      let analyzer = SpeechAnalyzer(modules: [module])
      guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
      else {
        throw AppleMeetingTranscriber.TranscriptionError.unavailable
      }
      let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(128))
      let worker = SpeechStream(
        analyzer: analyzer, format: format, input: stream.continuation,
        origin: origin, report: report)
      await worker.consume(module, streamID: streamID, participantID: participantID, result: result)
      do {
        try await analyzer.prepareToAnalyze(in: format)
        await worker.analyze(stream.stream)
      } catch {
        await worker.cancel()
        throw error
      }
      return worker
    }

    private func consume(
      _ module: SpeechTranscriber, streamID: String, participantID: String,
      result: @escaping @MainActor @Sendable (AppleMeetingTranscriber.Result) -> Void
    ) {
      resultsTask = Task { [report] in
        do {
          for try await item in module.results {
            await result(
              .init(
                streamID: streamID, participantID: participantID,
                start: item.range.start.seconds, end: item.range.end.seconds,
                text: String(item.text.characters), isFinal: item.isFinal))
          }
        } catch is CancellationError {} catch {
          await report("Transcription stopped for an audio stream: \(error.localizedDescription)")
        }
      }
    }

    private func analyze(_ sequence: AsyncStream<AnalyzerInput>) {
      analysisTask = Task { [analyzer, report] in
        do {
          if let lastSample = try await analyzer.analyzeSequence(sequence) {
            try await analyzer.finalizeAndFinish(through: lastSample)
          } else {
            await analyzer.cancelAndFinishNow()
          }
        } catch is CancellationError {} catch {
          await report("Speech analysis failed: \(error.localizedDescription)")
        }
      }
    }

    func push(_ frame: AudioPCMFrame) async {
      guard
        let sourceFormat = AVAudioFormat(
          commonFormat: .pcmFormatInt16,
          sampleRate: Double(frame.sampleRate), channels: AVAudioChannelCount(frame.channels),
          interleaved: true),
        let buffer = AVAudioPCMBuffer(
          pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frame.frameCount))
      else { return }
      buffer.frameLength = buffer.frameCapacity
      frame.samples.withUnsafeBytes { bytes in
        if let base = bytes.baseAddress,
          let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData
        {
          memcpy(destination, base, bytes.count)
        }
      }
      await push(buffer, at: frame.startTime)
    }

    func push(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) async {
      guard !ended else { return }
      do {
        if converter?.inputFormat != buffer.format {
          converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter,
          let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(
              ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 32)
        else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
          if consumed {
            status.pointee = .noDataNow
            return nil
          }
          consumed = true
          status.pointee = .haveData
          return buffer
        }
        if let error { throw error }
        guard output.frameLength > 0 else { return }
        let rate = CMTimeScale(format.sampleRate)
        let proposed = CMTime(seconds: max(0, time - origin), preferredTimescale: rate)
        // Decode callbacks jitter slightly. Use a continuous sample clock for
        // each stream, retaining real gaps instead of compressing silence.
        // Keep exact sample fractions: rounding each floating-point boundary
        // independently can overlap by a fraction of a sample, which causes
        // SpeechAnalyzer to terminate the stream with error 17.
        let start =
          previousEnd.map {
            abs(CMTimeSubtract(proposed, $0).seconds) < 0.1 ? $0 : CMTimeMaximum(proposed, $0)
          } ?? proposed
        previousEnd = CMTimeAdd(start, CMTime(value: Int64(output.frameLength), timescale: rate))
        if case .dropped = input.yield(AnalyzerInput(buffer: output, bufferStartTime: start)) {
          await report("Transcription fell behind; some audio could not be processed.")
        }
      } catch { await report("Audio conversion failed: \(error.localizedDescription)") }
    }

    func finish() async {
      guard !ended else { return }
      ended = true
      input.finish()
      // Speech can stall on errors or unavailable resources. A bounded finish
      // keeps hangup, saving and app termination responsive.
      let analyzer = analyzer
      let timeout = Task {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        await report("Finishing speech exceeded 30 seconds; unfinished text is retained.")
        await analyzer.cancelAndFinishNow()
      }
      await analysisTask?.value
      await resultsTask?.value
      timeout.cancel()
      resultsTask = nil
      analysisTask = nil
    }

    func cancel() async {
      ended = true
      input.finish()
      resultsTask?.cancel()
      analysisTask?.cancel()
      await analyzer.cancelAndFinishNow()
    }
  }
#endif
