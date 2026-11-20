import NetherNet
import Testing

@Test func serverDataV7MatchesTheLANAdvertisement() throws {
    let bytes: [UInt8] = [
        7, 1, 0x53, 0xd0, 0x0f, 1, 0x31, 1, 0x57, 1, 16, 4,
        0, 1, 0, 1, 2, 0x61, 0x62, 8
    ]
    let expected = ServerData(
        name: "S", world: "W", gameMode: 2, players: -1, capacity: 8, isHardcore: true,
        protocolVersion: 1000, gameVersion: "1", acceptsOnlineAuth: false, nonce: "ab"
    )
    #expect(try ServerData(decoding: bytes) == expected)
    #expect(try expected.encode(version: .v7) == bytes)
}

@Test func serverDataReadsOlderLayouts() throws {
    let v4: [UInt8] = [4, 1, 0x53, 1, 0x57, 4, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 4, 8]
    let v5: [UInt8] = [5, 1, 0x53, 1, 0x57, 4, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 1, 0, 4, 8]
    let v6: [UInt8] = [6, 1, 0x53, 1, 0x57, 4, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 1, 0, 1, 0x61, 4, 8]
    let versions: [ServerData.Version] = [.v4, .v5, .v6]
    for (bytes, version) in zip([v4, v5, v6], versions) {
        let data = try ServerData(decoding: bytes)
        #expect(data.name == "S" && data.world == "W" && data.gameMode == 2)
        #expect(data.acceptsSelfSignedAuth == (version == .v4))
        #expect(data.nonce == (version == .v6 ? "a" : ""))
        #expect(try data.encode(version: version) == bytes)
    }
    #expect(try ServerData(decoding: v4).encode() == v4)
}

@Test func serverDataRejectsAnOverflowingVariableLength() {
    let bytes: [UInt8] = [7, 0x80, 0x80, 0x80, 0x80, 0x10]
    #expect(throws: (any Error).self) { try ServerData(decoding: bytes) }
}
