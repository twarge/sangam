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
  /// One simulcast layer: the encoding SSRC and, when RTX was negotiated,
  /// its retransmission partner. WebRTC validates RTX all-or-nothing across
  /// layers — `SIM(a,b,c)` with a single `FID(a,r)` is rejected outright
  /// ("Failed to add send stream ssrc"), which is why the reference client
  /// follows its simulcast munging with RtxModifier: every layer gets a FID
  /// pair, or none does.
  private struct Layer {
    var ssrc: UInt32
    var rtx: UInt32?
  }

  private var ssrcCache: [String: [Layer]] = [:]

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

    let layers: [Layer]
    if let cached = ssrcCache[mid] {
      layers = cached
    } else {
      // The primary keeps its negotiated RTX partner; the generated layers
      // each get one exactly when the primary has one.
      let primaryRTX = Self.fidGroupMembers(in: lines).flatMap { $0.count > 1 ? $0[1] : nil }
      var used = Set(ssrcOrder)
      var generated: [Layer] = [Layer(ssrc: primary, rtx: primaryRTX)]
      for _ in 0..<2 {
        let ssrc = Self.uniqueSSRC(excluding: &used)
        let rtx = primaryRTX == nil ? nil : Self.uniqueSSRC(excluding: &used)
        generated.append(Layer(ssrc: ssrc, rtx: rtx))
      }
      layers = generated
      ssrcCache[mid] = generated
    }

    // Rewrite the section's source lines as the complete layered set: every
    // SSRC (layers and their RTX partners) shares the msid and cname, each
    // layer pairs with its RTX in a FID group, and the layers form the SIM
    // group. A renegotiation re-signals the identical set from the cache.
    lines.removeAll { $0.hasPrefix("a=ssrc:") || $0.hasPrefix("a=ssrc-group:") }
    for layer in layers {
      for ssrc in [layer.ssrc, layer.rtx].compactMap({ $0 }) {
        lines.append("a=ssrc:\(ssrc) msid:\(msid)")
        if let cname { lines.append("a=ssrc:\(ssrc) cname:\(cname)") }
      }
    }
    for layer in layers {
      if let rtx = layer.rtx {
        lines.append("a=ssrc-group:FID \(layer.ssrc) \(rtx)")
      }
    }
    lines.append(
      "a=ssrc-group:SIM \(layers.map { String($0.ssrc) }.joined(separator: " "))")
    if endsWithNewline { lines.append("") }
    return lines.joined(separator: newline)
  }

  private static func uniqueSSRC(excluding used: inout Set<UInt32>) -> UInt32 {
    var ssrc = UInt32.random(in: 1...0xFFFF_FFFE)
    while used.contains(ssrc) {
      ssrc = UInt32.random(in: 1...0xFFFF_FFFE)
    }
    used.insert(ssrc)
    return ssrc
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
