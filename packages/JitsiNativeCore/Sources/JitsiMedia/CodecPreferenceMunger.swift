import Foundation

/// Reorders video codec payloads in a local description so VP8 leads,
/// mirroring lib-jitsi-meet's `_mungeCodecOrder`. The encoder uses the first
/// payload of the m= line, and VP8 is the only codec this WebRTC build fans
/// out into SSRC-based simulcast layers — with the build's default H.264
/// preference the munged SIM group creates three encodings that never
/// encode, and the bridge gets a single stream it can never downshift.
enum CodecPreferenceMunger {
  static func preferVP8(_ sdp: String) -> String {
    let newline = sdp.contains("\r\n") ? "\r\n" : "\n"
    let sections = sdp.components(separatedBy: newline + "m=")
    guard sections.count > 1 else { return sdp }
    var rebuilt = [sections[0]]
    for section in sections.dropFirst() {
      rebuilt.append(section.hasPrefix("video") ? reorder(section, newline: newline) : section)
    }
    return rebuilt.joined(separator: newline + "m=")
  }

  private static func reorder(_ section: String, newline: String) -> String {
    var lines = section.components(separatedBy: newline)
    guard let mLine = lines.first else { return section }
    var parts = mLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard parts.count > 3 else { return section }
    let payloads = Array(parts[3...])

    var codecNames: [String: String] = [:]
    var rtxPartner: [String: String] = [:]
    for line in lines {
      if line.hasPrefix("a=rtpmap:") {
        let value = line.dropFirst("a=rtpmap:".count)
        let fields = value.split(separator: " ", maxSplits: 1)
        guard fields.count == 2 else { continue }
        let name = fields[1].split(separator: "/").first.map(String.init) ?? ""
        codecNames[String(fields[0])] = name.uppercased()
      } else if line.hasPrefix("a=fmtp:") {
        let value = line.dropFirst("a=fmtp:".count)
        let fields = value.split(separator: " ", maxSplits: 1)
        guard fields.count == 2, fields[1].hasPrefix("apt=") else { continue }
        rtxPartner[String(fields[0])] = String(fields[1].dropFirst("apt=".count))
      }
    }

    let preferred = payloads.filter { payload in
      codecNames[payload] == "VP8"
        || (codecNames[payload] == "RTX" && codecNames[rtxPartner[payload] ?? ""] == "VP8")
    }
    guard !preferred.isEmpty, preferred.first != payloads.first else { return section }
    let rest = payloads.filter { !preferred.contains($0) }
    parts.replaceSubrange(3..., with: preferred + rest)
    lines[0] = parts.joined(separator: " ")
    return lines.joined(separator: newline)
  }
}
