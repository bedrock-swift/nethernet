@testable import NetherNet
import Testing

@Test func openingReportsTheRemoteError() async throws {
    let connection = NetherNetConnection(
        networkID: 1, connectionID: 2, signaling: StubSignaling(), peer: StubPeer()
    )
    try await connection.start()
    #expect(try await connection.checkOpen() == false)

    let error = ConnectionError.remoteError("rejected")
    await #expect(throws: error) {
        try await connection.receive(Signal(kind: .error, connectionID: 2, data: "rejected"))
    }
    await connection.close()
    await #expect(throws: error) { try await connection.checkOpen() }
}

@Test func earlyCandidateDoesNotPreventStartingAnOffer() async throws {
    let connection = NetherNetConnection(
        networkID: 1, connectionID: 2, signaling: StubSignaling(), peer: StubPeer()
    )
    let candidate = Signal(kind: .candidate, connectionID: 2, data: "candidate")
    for _ in 0..<129 { try await connection.receive(candidate) }
    try await connection.start()
    await #expect(throws: ConnectionError.invalidSignal) {
        try await connection.receive(Signal(kind: .offer, connectionID: 2, data: "offer"))
    }
    try await connection.receive(Signal(kind: .answer, connectionID: 2, data: "answer"))
    await connection.close()
}

@Test(.timeLimit(.minutes(1))) func openingReportsNativePeerFailure() async throws {
    let peer = StubPeer()
    let connection = NetherNetConnection(networkID: 1, connectionID: 2, signaling: StubSignaling(), peer: peer)
    try await connection.start()
    peer.fail()
    var messages = connection.messages.makeAsyncIterator()
    do {
        _ = try await messages.next()
        Issue.record("missing WebRTC error")
    } catch {
        #expect(error as? WebRTCError == .connectionFailed)
    }
    await #expect(throws: WebRTCError.connectionFailed) { try await connection.checkOpen() }
}

private struct StubSignaling: NetherNetSignaling {
    func send(_ signal: Signal, to networkID: UInt64) async throws {}
}

private struct StubPeer: WebRTCPeer {
    private let stream = AsyncStream<PeerEvent>.makeStream()
    var events: AsyncStream<PeerEvent> { stream.stream }

    func offer() throws {}
    func remoteDescription(_ sdp: String, kind: Signal.Kind) throws {}
    func remoteCandidate(_ candidate: String) throws {}
    func send(_ segments: [[UInt8]], on channel: DataChannel) throws {}
    func close() { stream.continuation.finish() }
    func fail() { stream.continuation.yield(.failed(WebRTCError.connectionFailed)) }
}
