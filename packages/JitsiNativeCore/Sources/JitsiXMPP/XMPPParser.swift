import Foundation

public struct XMLBounds: Equatable, Sendable {
  public var maximumBytes: Int
  public var maximumDepth: Int
  public var maximumElements: Int
  public var maximumAttributesPerElement: Int
  public var maximumTextBytes: Int

  public init(
    maximumBytes: Int = 1_048_576,
    maximumDepth: Int = 64,
    maximumElements: Int = 10_000,
    maximumAttributesPerElement: Int = 64,
    maximumTextBytes: Int = 262_144
  ) {
    self.maximumBytes = maximumBytes
    self.maximumDepth = maximumDepth
    self.maximumElements = maximumElements
    self.maximumAttributesPerElement = maximumAttributesPerElement
    self.maximumTextBytes = maximumTextBytes
  }
}

public enum XMPPParsingError: Error, Equatable, Sendable {
  case emptyDocument
  case documentTooLarge(limit: Int)
  case documentTypeNotAllowed
  case malformedXML
  case nestingTooDeep(limit: Int)
  case tooManyElements(limit: Int)
  case tooManyAttributes(limit: Int)
  case textTooLarge(limit: Int)
  case multipleRootElements
}

// The transport parses every frame it reads, so these reach a join that got
// far enough to be answered by something that is not a Jitsi server — a proxy
// error page served where the XMPP WebSocket should be, most often.
extension XMPPParsingError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .emptyDocument:
      return "The Jitsi server sent an empty response."
    case .documentTooLarge(let limit):
      return "The Jitsi server's response exceeded the \(limit)-byte safety limit."
    case .documentTypeNotAllowed:
      return "The Jitsi server's response carried a document type, which is not allowed."
    case .malformedXML:
      return "The Jitsi server's response is not valid XMPP."
    case .nestingTooDeep(let limit):
      return "The Jitsi server's response nested deeper than the limit of \(limit)."
    case .tooManyElements(let limit):
      return "The Jitsi server's response held more than \(limit) elements."
    case .tooManyAttributes(let limit):
      return "The Jitsi server's response held more than \(limit) attributes on one element."
    case .textTooLarge(let limit):
      return "The Jitsi server's response held more than \(limit) bytes of text."
    case .multipleRootElements:
      return "The Jitsi server sent more than one document in a single frame."
    }
  }
}

public struct XMPPParser: Sendable {
  public var bounds: XMLBounds

  public init(bounds: XMLBounds = .init()) {
    self.bounds = bounds
  }

  public func parse(_ string: String) throws -> XMPPElement {
    try parse(Data(string.utf8))
  }

  public func parse(_ data: Data) throws -> XMPPElement {
    guard !data.isEmpty else { throw XMPPParsingError.emptyDocument }
    guard data.count <= bounds.maximumBytes else {
      throw XMPPParsingError.documentTooLarge(limit: bounds.maximumBytes)
    }

    let uppercasePrefix = String(decoding: data.prefix(4096), as: UTF8.self).uppercased()
    guard !uppercasePrefix.contains("<!DOCTYPE") && !uppercasePrefix.contains("<!ENTITY") else {
      throw XMPPParsingError.documentTypeNotAllowed
    }

    let delegate = TreeParserDelegate(bounds: bounds)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldProcessNamespaces = true
    parser.shouldReportNamespacePrefixes = false
    parser.shouldResolveExternalEntities = false

    guard parser.parse(), delegate.failure == nil else {
      throw delegate.failure ?? XMPPParsingError.malformedXML
    }
    guard let root = delegate.root else { throw XMPPParsingError.emptyDocument }
    return root
  }

  public func parseStanza(_ data: Data) throws -> XMPPStanza {
    XMPPStanza(element: try parse(data))
  }
}

private final class TreeParserDelegate: NSObject, XMLParserDelegate {
  private struct Builder {
    var name: String
    var namespace: String?
    var attributes: [String: String]
    var children: [XMPPElement] = []
    var text = ""
    var textBytes = 0
  }

  let bounds: XMLBounds
  var root: XMPPElement?
  var failure: XMPPParsingError?

  private var stack: [Builder] = []
  private var elementCount = 0

  init(bounds: XMLBounds) {
    self.bounds = bounds
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    guard failure == nil else { return }
    guard stack.count < bounds.maximumDepth else {
      fail(.nestingTooDeep(limit: bounds.maximumDepth), parser: parser)
      return
    }
    guard elementCount < bounds.maximumElements else {
      fail(.tooManyElements(limit: bounds.maximumElements), parser: parser)
      return
    }
    guard attributeDict.count <= bounds.maximumAttributesPerElement else {
      fail(.tooManyAttributes(limit: bounds.maximumAttributesPerElement), parser: parser)
      return
    }

    elementCount += 1
    stack.append(
      Builder(
        name: elementName,
        namespace: namespaceURI?.isEmpty == false ? namespaceURI : nil,
        attributes: attributeDict
      )
    )
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard failure == nil, !stack.isEmpty else { return }
    let bytes = string.utf8.count
    guard stack[stack.count - 1].textBytes + bytes <= bounds.maximumTextBytes else {
      fail(.textTooLarge(limit: bounds.maximumTextBytes), parser: parser)
      return
    }
    stack[stack.count - 1].text += string
    stack[stack.count - 1].textBytes += bytes
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard failure == nil, let builder = stack.popLast() else { return }
    let element = XMPPElement(
      name: builder.name,
      namespace: builder.namespace,
      attributes: builder.attributes,
      children: builder.children,
      text: builder.text.trimmingCharacters(in: .whitespacesAndNewlines)
    )

    if stack.isEmpty {
      guard root == nil else {
        fail(.multipleRootElements, parser: parser)
        return
      }
      root = element
    } else {
      stack[stack.count - 1].children.append(element)
    }
  }

  private func fail(_ error: XMPPParsingError, parser: XMLParser) {
    failure = error
    parser.abortParsing()
  }
}
