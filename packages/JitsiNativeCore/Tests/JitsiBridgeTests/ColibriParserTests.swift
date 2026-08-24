import Foundation
import Testing

@testable import JitsiBridge

@Test
func parsesDominantSpeaker() throws {
  let data = Data(
    #"{"colibriClass":"DominantSpeakerEndpointChangeEvent","dominantSpeakerEndpoint":"abc"}"#.utf8
  )
  #expect(try ColibriParser().parse(data) == .dominantSpeaker(endpointID: "abc"))
}

@Test
func parsesLastNChanges() throws {
  let data = Data(
    #"{"colibriClass":"LastNEndpointsChangeEvent","lastNEndpoints":["a","b"],"endpointsEnteringLastN":["b"],"endpointsLeavingLastN":["c"]}"#
      .utf8
  )
  #expect(
    try ColibriParser().parse(data)
      == .lastNChanged(current: ["a", "b"], entering: ["b"], leaving: ["c"])
  )
}

@Test
func parsesForwardedSourcesInBothSpellings() throws {
  let current = Data(
    #"{"colibriClass":"ForwardedSources","forwardedSources":["peer-v0","other-v0"]}"#.utf8
  )
  #expect(try ColibriParser().parse(current) == .forwardedSources(["peer-v0", "other-v0"]))
  let legacy = Data(
    #"{"colibriClass":"ForwardedSourcesChangeEvent","forwardedSources":[]}"#.utf8
  )
  #expect(try ColibriParser().parse(legacy) == .forwardedSources([]))
}

@Test
func parsesSenderConstraints() throws {
  let perSource = Data(
    #"{"colibriClass":"SenderSourceConstraints","sourceName":"me-v0","maxHeight":0}"#.utf8
  )
  #expect(
    try ColibriParser().parse(perSource)
      == .senderSourceConstraints(sourceName: "me-v0", maxHeight: 0)
  )
  let legacy = Data(
    #"{"colibriClass":"SenderVideoConstraints","videoConstraints":{"idealHeight":180}}"#.utf8
  )
  #expect(try ColibriParser().parse(legacy) == .senderVideoConstraints(idealHeight: 180))
}

@Test
func parsesServerHelloAndConnectionStats() throws {
  let hello = Data(#"{"colibriClass":"ServerHello","version":"2.3.1"}"#.utf8)
  #expect(try ColibriParser().parse(hello) == .serverHello(version: "2.3.1"))
  let stats = Data(
    #"{"colibriClass":"ConnectionStats","estimatedDownlinkBandwidth":2500000}"#.utf8
  )
  #expect(
    try ColibriParser().parse(stats)
      == .connectionStats(estimatedDownlinkBandwidthBps: 2_500_000)
  )
}

@Test
func encodesReceiverConstraints() throws {
  // Mirrors lib-jitsi-meet's steady-state message: lastN plus a per-source
  // height map and a default cap. No selectedSources/onStageSources — those
  // were removed upstream and must not reappear on the wire.
  let constraints = ReceiverVideoConstraints(
    lastN: 4,
    assumedBandwidthBps: -1,
    defaultConstraints: VideoConstraint(maxHeight: 180),
    constraints: ["presenter-v0": VideoConstraint(maxHeight: 1080)]
  )
  let object = try #require(
    JSONSerialization.jsonObject(with: constraints.encoded()) as? [String: Any]
  )

  #expect(object["colibriClass"] as? String == "ReceiverVideoConstraints")
  #expect(object["lastN"] as? Int == 4)
  #expect(object["assumedBandwidthBps"] as? Int == -1)
  #expect(object["selectedSources"] == nil)
  #expect(object["onStageSources"] == nil)
  let perSource = try #require(object["constraints"] as? [String: Any])
  let presenter = try #require(perSource["presenter-v0"] as? [String: Any])
  #expect(presenter["maxHeight"] as? Int == 1080)
  let defaults = try #require(object["defaultConstraints"] as? [String: Any])
  #expect(defaults["maxHeight"] as? Int == 180)
}

@Test
func omitsUnsetReceiverConstraintFields() throws {
  // The reference client's initial JVB message is just { lastN, assumedBandwidthBps }.
  let constraints = ReceiverVideoConstraints(lastN: -1, assumedBandwidthBps: -1)
  let object = try #require(
    JSONSerialization.jsonObject(with: constraints.encoded()) as? [String: Any]
  )
  #expect(object["lastN"] as? Int == -1)
  #expect(object["defaultConstraints"] == nil)
  #expect(object["constraints"] == nil)
}

@Test
func parsesVideoSourcesMap() throws {
  // Field names and types mirror jitsi-videobridge's `VideoSourceMapping`:
  // rtx is -1 when the source has no RTX partner, videoType arrives in the
  // bridge's uppercase enum spelling, and mid appears only under mid demux.
  let data = Data(
    #"""
    {"colibriClass":"VideoSourcesMap","mappedSources":[
      {"source":"abcd1234-v0","owner":"abcd1234","ssrc":555001,"rtx":555002,"videoType":"CAMERA"},
      {"source":"efgh5678-v1","owner":"efgh5678","ssrc":555003,"rtx":-1,"videoType":"DESKTOP","mid":"v1"},
      {"source":"","ssrc":1},
      {"source":"missing-ssrc-v0"}
    ]}
    """#.utf8
  )
  #expect(
    try ColibriParser().parse(data)
      == .sourcesRemapped(
        media: "video",
        sources: [
          MappedSource(
            sourceName: "abcd1234-v0",
            owner: "abcd1234",
            ssrc: 555_001,
            rtxSSRC: 555_002,
            videoType: "camera"
          ),
          MappedSource(
            sourceName: "efgh5678-v1",
            owner: "efgh5678",
            ssrc: 555_003,
            rtxSSRC: nil,
            mid: "v1",
            videoType: "desktop"
          ),
        ]
      )
  )
}

@Test
func parsesAudioSourcesMap() throws {
  let data = Data(
    #"{"colibriClass":"AudioSourcesMap","mappedSources":[{"source":"abcd1234-a0","owner":"abcd1234","ssrc":666001}]}"#
      .utf8
  )
  #expect(
    try ColibriParser().parse(data)
      == .sourcesRemapped(
        media: "audio",
        sources: [MappedSource(sourceName: "abcd1234-a0", owner: "abcd1234", ssrc: 666_001)]
      )
  )
}

@Test
func rejectsASourcesMapWithoutMappings() {
  let data = Data(#"{"colibriClass":"VideoSourcesMap"}"#.utf8)
  #expect(throws: ColibriParsingError.missingField(type: "VideoSourcesMap")) {
    try ColibriParser().parse(data)
  }
}

@Test
func boundsNestedMessages() {
  let data = Data(#"{"colibriClass":"EndpointMessage","msgPayload":{"a":{"b":true}}}"#.utf8)
  #expect(throws: ColibriParsingError.nestingTooDeep(limit: 1)) {
    try ColibriParser(maximumDepth: 1).parse(data)
  }
}

@Test
func preservesUnknownMessageClassWithoutPayload() throws {
  let data = Data(#"{"colibriClass":"FutureBridgeEvent","secret":"not retained"}"#.utf8)
  #expect(try ColibriParser().parse(data) == .unknown(type: "FutureBridgeEvent"))
}
