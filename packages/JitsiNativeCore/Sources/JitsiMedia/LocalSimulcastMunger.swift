import Foundation

/// Enables simulcast for outgoing video by munging the local answer before it
/// is installed, mirroring lib-jitsi-meet's `SdpSimulcast`: two additional
/// SSRCs are generated for the higher layers, given the primary's msid and
/// cname, and joined with it in a `SIM` group. WebRTC's engine reads the SIM
/// group from the local description and encodes three layers — the same
/// legacy-simulcast path the web client drives with identical munging.
///
/// Generated SSRCs are cached per mid: renegotiations must re-signal the same
/// layers, so a cache hit rewrites the media section to exactly the cached
/// SIM set, as the reference does.
struct LocalSimulcastMunger {
  private var ssrcCache: [String: [UInt32]] = [:]

  /// Munges every *sending* video section of a local description. Sections
  /// that are receive-only or inactive, carry no sources, or already signal
  /// more than a primary+RTX pair are left untouched.
  mutating func munge(_ sdp: String) -> String {
    let newline = sdp.contains("\r\n") ? "\r\n" : "\n"
    var sections = Self.split(sdp, newline: newline)
    for index in sections.indices.dropFirst() {
      sections[index] = munge(section: sections[index], newline: newline)
    }
    return sections.joined(separator: newline)
  }

  private mutating func munge(section: String, newline: String) -> String {
    var lines = section.components(separatedBy: newline)
    // The final section carries the SDP's trailing newline as an empty last
    // element; appending after it would put a blank line mid-SDP, which
    // WebRTC rejects outright.
    let endsWithNewline = lines.last == ""
    if endsWithNewline { lines.removeLast() }
    guard
      lines.first?.hasPrefix("m=video") == true,
      !lines.contains("a=recvonly"),
      !lines.contains("a=inactive"),
      let mid = Self.value(of: "a=mid:", in: lines)
    else { return section }

    let ssrcOrder = Self.orderedSSRCs(in: lines)
    let groupCount = lines.count { $0.hasPrefix("a=ssrc-group:") }
    // Nothing to layer (no sources), or already simulcast.
    guard
      !ssrcOrder.isEmpty, ssrcOrder.count <= 2,
      !(ssrcOrder.count == 2 && groupCount == 0)
    else { return section }

    let primary: UInt32
    if ssrcOrder.count == 1 {
      primary = ssrcOrder[0]
    } else if let fid = Self.fidGroupMembers(in: lines)?.first {
      primary = fid
    } else {
      return section
    }

    // WebRTC's answers may carry the msid only at media level, with just
    // cnames on the ssrc lines.
    let msid =
      Self.ssrcAttribute(primary, "msid", in: lines) ?? Self.value(of: "a=msid:", in: lines)
    guard let msid else { return section }
    let cname = Self.ssrcAttribute(primary, "cname", in: lines)

    if let cached = ssrcCache[mid] {
      // A renegotiation must re-signal the very same layers: replace the
      // fresh source lines with the cached SIM set.
      lines.removeAll { $0.hasPrefix("a=ssrc:") || $0.hasPrefix("a=ssrc-group:") }
      for ssrc in cached {
        lines.append("a=ssrc:\(ssrc) msid:\(msid)")
        if let cname { lines.append("a=ssrc:\(ssrc) cname:\(cname)") }
      }
      lines.append("a=ssrc-group:SIM \(cached.map(String.init).joined(separator: " "))")
    } else {
      // Make the msid explicit on the existing ssrc lines, generate the two
      // higher layers, and join them with the primary in a SIM group. The
      // primary's FID (RTX) group is left as negotiated.
      for ssrc in ssrcOrder where Self.ssrcAttribute(ssrc, "msid", in: lines) == nil {
        lines.append("a=ssrc:\(ssrc) msid:\(msid)")
      }
      var layers = [primary]
      for _ in 0..<2 {
        var ssrc = UInt32.random(in: 1...0xFFFF_FFFE)
        while layers.contains(ssrc) || ssrcOrder.contains(ssrc) {
          ssrc = UInt32.random(in: 1...0xFFFF_FFFE)
        }
        layers.append(ssrc)
        lines.append("a=ssrc:\(ssrc) msid:\(msid)")
        if let cname { lines.append("a=ssrc:\(ssrc) cname:\(cname)") }
      }
      lines.append("a=ssrc-group:SIM \(layers.map(String.init).joined(separator: " "))")
      ssrcCache[mid] = layers
    }
    if endsWithNewline { lines.append("") }
    return lines.joined(separator: newline)
  }

  /// Splits an SDP into the session part followed by one string per media
  /// section, preserving content exactly.
  private static func split(_ sdp: String, newline: String) -> [String] {
    var sections: [[String]] = [[]]
    for line in sdp.components(separatedBy: newline) {
      if line.hasPrefix("m=") { sections.append([]) }
      sections[sections.count - 1].append(line)
    }
    return sections.map { $0.joined(separator: newline) }
  }

  private static func orderedSSRCs(in lines: [String]) -> [UInt32] {
    var seen = Set<UInt32>()
    var order: [UInt32] = []
    for line in lines where line.hasPrefix("a=ssrc:") {
      let rest = line.dropFirst("a=ssrc:".count)
      guard let ssrc = UInt32(rest.prefix(while: { $0 != " " })) else { continue }
      if seen.insert(ssrc).inserted { order.append(ssrc) }
    }
    return order
  }

  private static func fidGroupMembers(in lines: [String]) -> [UInt32]? {
    for line in lines where line.hasPrefix("a=ssrc-group:FID ") {
      let members = line.dropFirst("a=ssrc-group:FID ".count)
        .split(separator: " ")
        .compactMap { UInt32($0) }
      if !members.isEmpty { return members }
    }
    return nil
  }

  private static func ssrcAttribute(
    _ ssrc: UInt32, _ name: String, in lines: [String]
  ) -> String? {
    let prefix = "a=ssrc:\(ssrc) \(name):"
    return lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
  }

  private static func value(of prefix: String, in lines: [String]) -> String? {
    lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
  }
}
