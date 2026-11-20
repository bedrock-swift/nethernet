@testable import NetherNet
import Testing

@Test(.timeLimit(.minutes(1))) func browseRepeatsDiscoveryAndEndsOnClose() async throws {
    let address = LANAddress(address: 0x7f00_0001, port: 0)
    let receiver = try LANSocket(bindTo: address, receiveTimeout: 1_000)
    let client = try NetherNetLAN(on: address, networkID: 1) { throw ConnectionError.invalidSignal }
    let browsing = Task { try await client.browse(at: receiver.localAddress, every: .milliseconds(20)) }
    defer { browsing.cancel() }

    var buffer = [UInt8](repeating: 0, count: 128)
    let expected = DiscoveryPacket(sender: 1, body: .request)
    for _ in 0..<2 {
        let input = try #require(try receiver.receive(into: &buffer))
        #expect(try DiscoveryPacket(decoding: input.bytes) == expected)
    }
    await client.close()
    try await browsing.value
}
