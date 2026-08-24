import CoreImage
import Foundation
import ReplayKit

final class SampleUploader: @unchecked Sendable {
  private static let imageContext = CIContext(options: nil)
  private static let maximumChunkLength = 10_240

  private let connection: SocketConnection
  private let queue = DispatchQueue(label: "com.twarge.sangam.broadcast.uploader")
  private var dataToSend: Data?
  private var byteIndex = 0
  private var isReady = false

  init(connection: SocketConnection) {
    self.connection = connection
    connection.didOpen = { [weak self] in
      guard let self else { return }
      queue.async { [self] in isReady = true }
    }
    connection.streamHasSpaceAvailable = { [weak self] in
      guard let self else { return }
      queue.async { [self] in sendNextChunk() }
    }
  }

  func send(_ sampleBuffer: CMSampleBuffer) {
    guard let message = prepare(sampleBuffer) else { return }
    queue.async { [weak self] in
      guard let self, isReady else { return }
      isReady = false
      dataToSend = message
      byteIndex = 0
      sendNextChunk()
    }
  }

  private func sendNextChunk() {
    guard let dataToSend else {
      isReady = true
      return
    }

    let bytesLeft = dataToSend.count - byteIndex
    guard bytesLeft > 0 else {
      self.dataToSend = nil
      byteIndex = 0
      isReady = true
      return
    }

    let desiredLength = min(bytesLeft, Self.maximumChunkLength)
    let written = dataToSend[byteIndex..<(byteIndex + desiredLength)].withUnsafeBytes { bytes in
      guard let pointer = bytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
      return connection.write(buffer: pointer, maximumLength: desiredLength)
    }

    if written > 0 {
      byteIndex += written
      if byteIndex == dataToSend.count {
        self.dataToSend = nil
        byteIndex = 0
        isReady = true
      }
    }
  }

  private func prepare(_ sampleBuffer: CMSampleBuffer) -> Data? {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
    let scale = CGAffineTransform(scaleX: 0.5, y: 0.5)
    let image = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: scale)
    guard let colorSpace = image.colorSpace else { return nil }

    let options: [CIImageRepresentationOption: Any] = [
      kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.82
    ]
    guard
      let jpeg = Self.imageContext.jpegRepresentation(
        of: image,
        colorSpace: colorSpace,
        options: options
      )
    else { return nil }

    let width = CVPixelBufferGetWidth(pixelBuffer) / 2
    let height = CVPixelBufferGetHeight(pixelBuffer) / 2
    let orientation =
      CMGetAttachment(
        sampleBuffer,
        key: RPVideoSampleOrientationKey as CFString,
        attachmentModeOut: nil
      )?.uintValue ?? 0

    let response = CFHTTPMessageCreateResponse(nil, 200, nil, kCFHTTPVersion1_1).takeRetainedValue()
    CFHTTPMessageSetHeaderFieldValue(
      response, "Content-Length" as CFString, "\(jpeg.count)" as CFString)
    CFHTTPMessageSetHeaderFieldValue(response, "Buffer-Width" as CFString, "\(width)" as CFString)
    CFHTTPMessageSetHeaderFieldValue(response, "Buffer-Height" as CFString, "\(height)" as CFString)
    CFHTTPMessageSetHeaderFieldValue(
      response,
      "Buffer-Orientation" as CFString,
      "\(orientation)" as CFString
    )
    CFHTTPMessageSetBody(response, jpeg as CFData)
    return CFHTTPMessageCopySerializedMessage(response)?.takeRetainedValue() as Data?
  }
}
