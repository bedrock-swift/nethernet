import Foundation
import Testing
@testable import NetherNet

@Test(.enabled(if: ProcessInfo.processInfo.environment["NETHERNET_TEST_LIBRARY"] != nil))
func nativePeerAdvertisesTheConfiguredICEPort() async throws {
    let library = try #require(ProcessInfo.processInfo.environment["NETHERNET_TEST_LIBRARY"])
    let port = try LANSocket(bindTo: LANAddress(address: 0, port: 0)).localAddress.port
    let api = try LibDataChannel(libraryPath: library, icePorts: port...port)
    let peer = try api.makePeer(trickleICE: false)
    defer { peer.close() }
    try peer.offer()
    let sdp = try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            for await event in peer.events {
                if case .description(.offer, let sdp) = event { return sdp }
                if case .failed(let error) = event { throw error }
            }
            throw ConnectionError.closed
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw HTTPJoinError.timedOut
        }
        defer { group.cancelAll() }
        return try #require(try await group.next())
    }
    let candidatePorts = sdp.split(whereSeparator: \.isNewline).compactMap { line -> UInt16? in
        guard line.hasPrefix("a=candidate:") else { return nil }
        let fields = line.split(separator: " ")
        return fields.count > 5 ? UInt16(fields[5]) : nil
    }
    #expect(!candidatePorts.isEmpty)
    #expect(candidatePorts.allSatisfy { $0 == port })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NETHERNET_TEST_LIBRARY"] != nil))
func nativePeersExchangeFragmentedMessages() async throws {
    let library = try #require(ProcessInfo.processInfo.environment["NETHERNET_TEST_LIBRARY"])
    let api = try LibDataChannel(libraryPath: library)
    let address = LANAddress(address: 0x7f000001, port: 0)
    let server = try NetherNetLAN(on: address, advertisement: [1]) { try api.makePeer() }
    let client = try NetherNetLAN(on: address) { try api.makePeer() }
    await server.start()

    let payload = (0..<25_000).map { UInt8(truncatingIfNeeded: $0) }
    let reply = try await withThrowingTaskGroup(of: [UInt8].self) { group in
        group.addTask {
            try await client.discover(at: server.localAddress)
            var advertisements = client.advertisements.makeAsyncIterator()
            let advertisement = try #require(await advertisements.next())
            let sender = try await client.connect(to: advertisement.networkID)
            var accepted = server.connections.makeAsyncIterator()
            let receiver = try #require(await accepted.next())
            try await sender.send(payload)
            var incoming = receiver.messages.makeAsyncIterator()
            let received = try #require(try await incoming.next())
            try await receiver.send(received)
            var result = sender.messages.makeAsyncIterator()
            return try #require(try await result.next())
        }
        group.addTask {
            try await Task.sleep(for: .seconds(12))
            throw LANError.timedOut
        }
        defer { group.cancelAll() }
        do {
            return try #require(try await group.next())
        } catch {
            await client.close()
            await server.close()
            throw error
        }
    }
    await client.close()
    await server.close()
    #expect(reply == payload)
}
