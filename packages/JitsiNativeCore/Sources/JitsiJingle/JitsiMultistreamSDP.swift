import Foundation

public enum JitsiMultistreamSDPError: Error, Equatable, Sendable {
  case malformedSDP
  case missingMedia(String)
  case missingMID(String)
  case missingLocalSources(String)
}

public struct JitsiMultistreamAddition: Equatable, Sendable {
  public var sdp: String
  public var mid: String

  public init(sdp: String, mid: String) {
    self.sdp = sdp
    self.mid = mid
  }
}

/// Pure SDP mutations used by Jitsi's Unified Plan multi-stream signaling.
///
/// Jicofo's original offer does not allocate a transceiver for a second local
/// video source. lib-jitsi-meet solves that by cloning a remote video m-line as
/// recv-only, answering it, attaching the local track, and answering again.
public struct JitsiMultistreamSDP: Sendable {
  public init() {}

  public func addingLocalSourceMedia(
    to remoteOffer: String,
    kind: String = "video"
  ) throws -> JitsiMultistreamAddition {
    var document = try Document(remoteOffer)
    guard let template = document.media.first(where: { $0.kind == kind }) else {
      throw JitsiMultistreamSDPError.missingMedia(kind)
    }

    let mid = document.nextMID
    var addition = template
    addition.lines.removeAll(where: Self.isSourceOrDirectionLine)
    addition.lines.append("a=mid:\(mid)")
    addition.lines.append("a=recvonly")
    document.media.append(addition)
    document.appendToBundle(mid)
    document.incrementOriginVersion()
    return JitsiMultistreamAddition(sdp: document.serialized, mid: mid)
  }

  /// Describes the local source on media line `mid` as a Jingle content for a
  /// source-add. Like lib-jitsi-meet's `SDPDiffer.toJingle` for a bridge
  /// session, the content is named by media type — not by mid — and each
  /// source carries its name and video type as XML attributes with only the
  /// msid as a parameter.
  public func sourceContent(
    from localSDP: String,
    mid: String,
    metadata: LocalSourceMetadata
  ) throws -> JingleContent {
    let document = try Document(localSDP)
    guard let media = document.media.first(where: { $0.mid == mid }) else {
      throw JitsiMultistreamSDPError.missingMID(mid)
    }
    let sources = Self.sources(in: media, metadata: metadata)
    guard !sources.isEmpty else {
      throw JitsiMultistreamSDPError.missingLocalSources(mid)
    }
    return JingleContent(
      name: media.kind,
      creator: "initiator",
      senders: "responder",
      description: RTPDescription(
        media: media.kind,
        sources: sources,
        sourceGroups: Self.sourceGroups(in: media)
      )
    )
  }

  /// Applies source-add/source-remove to the offer currently installed on the
  /// peer connection, following lib-jitsi-meet's `_processSourceMapFromJingle`
  /// plus `SDP.updateRemoteSources`: sources are grouped by source name — the
  /// content name means nothing here — every added source gets a **fresh**
  /// send-only media line (using the bridge-provided `mid` parameter when SSRC
  /// rewriting supplies one, the next sequential identifier otherwise) whose
  /// `a=ssrc:` lines carry only the msid, and a removed source's media line is
  /// rejected outright so WebRTC drops the transceiver instead of reusing it.
  /// The returned SDP is ready for an answer renegotiation.
  public func applyingRemoteSourceUpdate(
    _ session: JingleSessionDescription,
    to remoteOffer: String
  ) throws -> String {
    var document = try Document(remoteOffer)

    struct SourceInfo {
      var media: String
      var msid: String?
      var mid: String?
      var ssrcs: [UInt32] = []
      var groups: [RTPSourceGroup] = []
    }
    var order: [String] = []
    var infoByName: [String: SourceInfo] = [:]
    for content in session.contents {
      guard let description = content.description, !description.sources.isEmpty else { continue }
      for source in description.sources {
        let key = source.sourceName ?? "ssrc:\(source.ssrc)"
        if infoByName[key] == nil {
          infoByName[key] = SourceInfo(
            media: description.media,
            msid: source.parameters["msid"],
            mid: source.parameters["mid"]
          )
          order.append(key)
        }
        infoByName[key]?.ssrcs.append(source.ssrc)
      }
      // A group belongs to the source whose ssrc list it matches exactly.
      for group in description.sourceGroups {
        let members = group.sources.sorted()
        for key in order where infoByName[key]?.ssrcs.sorted() == members {
          infoByName[key]?.groups.append(group)
        }
      }
    }

    for key in order {
      guard let info = infoByName[key] else { continue }
      switch session.action {
      case .sourceAdd:
        // Without an msid there is nothing to put on the new media line.
        guard let msid = info.msid else { continue }
        guard var clone = document.media.first(where: { $0.kind == info.media }) else {
          throw JitsiMultistreamSDPError.missingMedia(info.media)
        }
        clone.lines.removeAll(where: Self.isSourceOrDirectionLine)
        let mid = info.mid ?? document.nextMID
        clone.lines.append("a=mid:\(mid)")
        clone.lines.append("a=sendonly")
        // Media-level msid so WebRTC surfaces the remote track under the
        // signaled id instead of synthesizing one.
        clone.lines.append("a=msid:\(msid)")
        for ssrc in info.ssrcs {
          clone.lines.append("a=ssrc:\(ssrc) msid:\(msid)")
        }
        for group in info.groups where !group.sources.isEmpty {
          clone.lines.append(
            "a=ssrc-group:\(group.semantics) "
              + group.sources.map(String.init).joined(separator: " ")
          )
        }
        document.media.append(clone)
        document.appendToBundle(mid)
      case .sourceRemove:
        guard
          let firstSSRC = info.ssrcs.first,
          let mediaIndex = document.media.firstIndex(where: { section in
            section.lines.contains { Self.ssrc(from: $0) == firstSSRC }
          })
        else { continue }
        let removed = Set(info.ssrcs)
        document.media[mediaIndex].lines.removeAll { line in
          if let ssrc = Self.ssrc(from: line), removed.contains(ssrc) { return true }
          if line.hasPrefix("a=ssrc-group:") {
            return line.split(separator: " ").dropFirst().compactMap { UInt32($0) }
              .contains(where: removed.contains)
          }
          return false
        }
        document.media[mediaIndex].reject()
      default:
        break
      }
    }
    document.incrementOriginVersion()
    return document.serialized
  }

  private static func sources(
    in media: MediaSection,
    metadata: LocalSourceMetadata
  ) -> [RTPSource] {
    var parameters: [UInt32: [String: String]] = [:]
    for line in media.lines where line.hasPrefix("a=ssrc:") {
      let value = String(line.dropFirst("a=ssrc:".count))
      let pair = value.split(separator: " ", maxSplits: 1)
      guard pair.count == 2, let ssrc = UInt32(pair[0]) else { continue }
      let property = pair[1].split(
        separator: ":",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      guard property.count == 2 else { continue }
      parameters[ssrc, default: [:]][String(property[0])] = String(property[1])
    }
    for group in sourceGroups(in: media) {
      for ssrc in group.sources where parameters[ssrc] == nil { parameters[ssrc] = [:] }
    }
    return parameters.keys.sorted().map { ssrc in
      RTPSource(
        ssrc: ssrc,
        name: metadata.name,
        videoType: metadata.videoType,
        parameters: (parameters[ssrc]?["msid"]).map { ["msid": $0] } ?? [:]
      )
    }
  }

  private static func sourceGroups(in media: MediaSection) -> [RTPSourceGroup] {
    media.lines.compactMap { line in
      guard line.hasPrefix("a=ssrc-group:") else { return nil }
      let parts = line.dropFirst("a=ssrc-group:".count).split(separator: " ")
      guard let semantics = parts.first, parts.count > 1 else { return nil }
      return RTPSourceGroup(
        semantics: String(semantics),
        sources: parts.dropFirst().compactMap { UInt32($0) }
      )
    }
  }

  private static func isSourceOrDirectionLine(_ line: String) -> Bool {
    line.hasPrefix("a=mid:") || line == "a=sendrecv" || line == "a=sendonly"
      || line == "a=recvonly" || line == "a=inactive" || line.hasPrefix("a=msid:")
      || line.hasPrefix("a=ssrc:") || line.hasPrefix("a=ssrc-group:")
  }

  private static func ssrc(from line: String) -> UInt32? {
    guard line.hasPrefix("a=ssrc:") else { return nil }
    return UInt32(line.dropFirst("a=ssrc:".count).split(separator: " ", maxSplits: 1)[0])
  }
}

private struct Document {
  var session: [String]
  var media: [MediaSection]
  var usesCRLF: Bool

  init(_ sdp: String) throws {
    usesCRLF = sdp.contains("\r\n")
    let normalized = sdp.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    guard !lines.isEmpty, lines[0] == "v=0" else {
      throw JitsiMultistreamSDPError.malformedSDP
    }
    var sessionLines: [String] = []
    var sections: [MediaSection] = []
    for line in lines {
      if line.hasPrefix("m=") {
        sections.append(MediaSection(lines: [line]))
      } else if sections.isEmpty {
        sessionLines.append(line)
      } else {
        sections[sections.count - 1].lines.append(line)
      }
    }
    guard !sections.isEmpty else { throw JitsiMultistreamSDPError.malformedSDP }
    session = sessionLines
    media = sections
  }

  var nextMID: String {
    let numeric = media.compactMap { $0.mid.flatMap(Int.init) }
    return String(max(media.count, (numeric.max() ?? -1) + 1))
  }

  var serialized: String {
    let separator = usesCRLF ? "\r\n" : "\n"
    return (session + media.flatMap(\.lines)).joined(separator: separator) + separator
  }

  mutating func appendToBundle(_ mid: String) {
    if let index = session.firstIndex(where: { $0.hasPrefix("a=group:BUNDLE") }) {
      let existing = session[index].split(separator: " ").dropFirst().map(String.init)
      if !existing.contains(mid) { session[index] += " \(mid)" }
    } else {
      session.append("a=group:BUNDLE \(mid)")
    }
  }

  mutating func incrementOriginVersion() {
    guard let index = session.firstIndex(where: { $0.hasPrefix("o=") }) else { return }
    var parts = session[index].split(separator: " ", omittingEmptySubsequences: false).map(
      String.init)
    guard parts.count >= 3, let version = UInt64(parts[2]) else { return }
    parts[2] = String(version &+ 1)
    session[index] = parts.joined(separator: " ")
  }
}

private struct MediaSection {
  var lines: [String]

  var kind: String {
    lines.first?.dropFirst(2).split(separator: " ").first.map(String.init) ?? ""
  }

  var mid: String? {
    lines.first(where: { $0.hasPrefix("a=mid:") }).map {
      String($0.dropFirst("a=mid:".count))
    }
  }

  mutating func removeDirection() {
    lines.removeAll { ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains($0) }
  }

  mutating func reject() {
    guard let first = lines.first else { return }
    var parts = first.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    if parts.count > 1 { parts[1] = "0" }
    lines[0] = parts.joined(separator: " ")
    removeDirection()
    lines.append("a=inactive")
  }
}
