import NetherNet
import Testing

@Test func signalPreservesCandidateAndSDPSpacing() throws {
    let signal = try Signal(parsing: "CANDIDATEADD 18446744073709551615 candidate:a 1 udp")
    #expect(signal.kind == .candidate)
    #expect(signal.connectionID == .max)
    #expect(signal.text == "CANDIDATEADD 18446744073709551615 candidate:a 1 udp")
    #expect(throws: (any Error).self) { try Signal(parsing: "CONNECTREQUEST -1 data") }
}

@Test func discoveryRoutesRequestsAndAddressedSignals() throws {
    let advertisement = try ServerData(name: "Swift", world: "Test").encode()
    var client = LANDiscovery<String>(networkID: 1)
    var server = LANDiscovery<String>(networkID: 2, advertisement: advertisement)
    let received = try server.receive(client.request(), from: "client")
    let reply = try #require(received.reply)
    let pong = try client.receive(reply, from: "server")
    #expect(pong.event == .advertisement(networkID: 2, payload: advertisement, from: "server"))
    #expect(try ServerData(decoding: advertisement).world == "Test")
    #expect(client.endpoint(for: 2) == "server")

    let offer = Signal(kind: .offer, connectionID: 300, data: "v=0\r\n")
    let ignored = try server.receive(client.message(offer, to: 3), from: "client")
    let signal = try server.receive(client.message(offer, to: 2), from: "client")
    #expect(ignored.event == nil)
    #expect(signal.event == .signal(offer, networkID: 1, from: "client"))
    var corrupted = reply
    corrupted[0] ^= 1
    #expect(throws: (any Error).self) { try DiscoveryPacket(decoding: corrupted) }
}

@Test func fragmentedPayloadRejectsOutOfOrderSegments() throws {
    let bytes = [UInt8](repeating: 0xa5, count: 20_100)
    let segments = try MessageCodec.encode(bytes)
    #expect(segments.map { $0[0] } == [2, 1, 0])
    var decoder = MessageCodec()
    let first = try decoder.receive(segments[0])
    #expect(first == nil)
    #expect(throws: (any Error).self) { try decoder.receive(segments[2]) }
    let second = try decoder.receive(segments[1])
    let complete = try decoder.receive(segments[2])
    #expect(second == nil)
    #expect(complete == bytes)
    #expect(throws: (any Error).self) { try MessageCodec.encode(bytes, reliable: false) }
}

@Test func discoveryMatchesIndependentWireFixture() throws {
    let expected: [UInt8] = [
        0x99, 0x53, 0xe2, 0x9e, 0x85, 0x7c, 0xe3, 0x4d,
        0xa7, 0x87, 0xd4, 0xb2, 0x4a, 0xfd, 0x97, 0xa4,
        0x42, 0x38, 0x08, 0xc5, 0x2d, 0x4e, 0x66, 0x15,
        0x7e, 0xaf, 0x0c, 0xf2, 0xd2, 0xd8, 0xd2, 0x2c,
        0x1b, 0x70, 0xdc, 0x75, 0xfe, 0x0a, 0x44, 0xf0,
        0xf7, 0x77, 0xba, 0xf1, 0x28, 0x5b, 0x5c, 0x55,
        0xff, 0x0f, 0x87, 0x09, 0xe1, 0x3b, 0xf6, 0x85,
        0x8e, 0x20, 0x51, 0xc3, 0x21, 0xdb, 0x61, 0x5e
    ]
    let request = DiscoveryPacket(sender: 0x0102_0304_0506_0708, body: .request)
    #expect(try request.encode() == expected)
    #expect(try DiscoveryPacket(decoding: expected) == request)
}

@Test func discoveryAcceptsLengthIncludingThePrefix() throws {
    let request: [UInt8] = [
        0xa8, 0xe8, 0x1a, 0xcc, 0x35, 0xf9, 0x26, 0xc4,
        0x83, 0x3f, 0xfb, 0xac, 0xe5, 0x8a, 0x31, 0x85,
        0x04, 0x8b, 0x21, 0x62, 0xa3, 0xd3, 0x53, 0x62,
        0xd2, 0x2a, 0x01, 0xa0, 0xc1, 0x8e, 0x48, 0x61,
        0xef, 0x11, 0xb5, 0x69, 0x6a, 0x11, 0x70, 0x67,
        0x16, 0xbc, 0xf8, 0x88, 0xed, 0x20, 0xc8, 0x13,
        0xff, 0x0f, 0x87, 0x09, 0xe1, 0x3b, 0xf6, 0x85,
        0x8e, 0x20, 0x51, 0xc3, 0x21, 0xdb, 0x61, 0x5e
    ]
    #expect(try DiscoveryPacket(decoding: request) == DiscoveryPacket(sender: 1, body: .request))
}

@Test func receivesACompleteMessageOverTheSendFragmentSize() throws {
    var decoder = MessageCodec()
    let payload = [UInt8](repeating: 0xab, count: 20_100)
    let decoded = try decoder.receive([0] + payload)
    #expect(decoded == payload)
}

@Test func discoveryCapsDeclaredSignalLengthWithoutTruncatingData() throws {
    let offer = Signal(kind: .offer, connectionID: 3, data: String(repeating: "a", count: 1_140))
    let packet = DiscoveryPacket(sender: 1, body: .message(recipient: 2, offer))
    let expectedTag: [UInt8] = [
        0xfb, 0x22, 0xb6, 0x12, 0xb9, 0xe2, 0x97, 0xd7,
        0xe6, 0xf3, 0x73, 0x3d, 0x9a, 0xe1, 0x53, 0xa9,
        0x64, 0x9e, 0x98, 0x7f, 0x6d, 0xa4, 0x1b, 0xa3,
        0x81, 0xe1, 0xd2, 0x68, 0xa2, 0xbf, 0x6d, 0x4e
    ]
    let encoded = try packet.encode()
    #expect(Array(encoded.prefix(32)) == expectedTag)
    #expect(try DiscoveryPacket(decoding: encoded) == packet)
}
