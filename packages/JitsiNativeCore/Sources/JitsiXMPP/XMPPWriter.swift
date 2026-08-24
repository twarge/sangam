import Foundation

public enum XMPPWriter {
  public static func serialize(_ element: XMPPElement) -> String {
    var result = "<\(element.name)"
    if let namespace = element.namespace {
      result += " xmlns=\"\(escapeAttribute(namespace))\""
    }
    for key in element.attributes.keys.sorted() {
      guard let value = element.attributes[key] else { continue }
      result += " \(key)=\"\(escapeAttribute(value))\""
    }

    if element.children.isEmpty && element.text.isEmpty {
      return result + "/>"
    }

    result += ">"
    result += escapeText(element.text)
    result += element.children.map(serialize).joined()
    result += "</\(element.name)>"
    return result
  }

  private static func escapeAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private static func escapeText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
