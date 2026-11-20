import NetherNet
import Testing

@Test func sdpIdentityDecodesNestedJSONAndAddsASessionAttribute() throws {
    let attribute = "a=identity:eyJpZHAiOnsiZG9tYWluIjoiZXhhbXBsZS50ZXN0IiwicHJvdG9jb2wiOiJkZWZhdWx0In0sImFzc2VydGlvbiI6IntcInRva2VuXCI6XCJlMzAuZTMwLkFBXCIsXCJmaW5nZXJwcmludHNcIjpcImUzMC4uQUFcIn0ifQ=="
    let sdp = ["v=0", attribute, "m=application 9 UDP/DTLS/SCTP webrtc-datachannel"].joined(separator: "\r\n")
    let identity = try SDPIdentity(sdp: sdp)
    #expect(identity.domain == "example.test")
    #expect(identity.token == "e30.e30.AA")
    #expect(identity.fingerprintSignature == "e30..AA")

    let inserted = try identity.adding(to: "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n")
    #expect(inserted.hasPrefix("v=0\r\na=identity:"))
    #expect(try SDPIdentity(sdp: inserted) == identity)
    #expect(throws: SDPIdentityError.duplicate) { try SDPIdentity(sdp: sdp + "\r\n" + attribute) }
}

@Test func sdpFingerprintPayloadUsesCanonicalJSONAndPreservesOrder() throws {
    let sdp = "v=0\r\na=fingerprint:sha-256 AB:CD\r\na=fingerprint:sha-384 EF:F0\r\n"
    let json = String(decoding: try SDPIdentity.fingerprintPayload(in: sdp), as: UTF8.self)
    #expect(json == #"{"fingerprint":[{"algorithm":"sha-256","digest":"AB:CD"},{"algorithm":"sha-384","digest":"EF:F0"}]}"#)
    #expect(throws: SDPIdentityError.missing) { try SDPIdentity.fingerprintPayload(in: "v=0\r\n") }
}
