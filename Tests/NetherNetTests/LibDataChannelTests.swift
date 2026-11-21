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
