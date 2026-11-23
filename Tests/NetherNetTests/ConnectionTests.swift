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

@Test(.timeLimit(.minutes(1)), arguments: [WebRTCError.connectionFailed, .dataChannelFailed(.reliable)])
func openingReportsNativePeerFailure(_ failure: WebRTCError) async throws {
    let peer = StubPeer()
    let connection = NetherNetConnection(networkID: 1, connectionID: 2, signaling: StubSignaling(), peer: peer)
    try await connection.start()
    peer.fail(failure)
    var messages = connection.messages.makeAsyncIterator()
    do {
        _ = try await messages.next()
        Issue.record("missing WebRTC error")
    } catch {
        #expect(error as? WebRTCError == failure)
    }
    await #expect(throws: failure) { try await connection.checkOpen() }
}

@Test func sendQueuePressureKeepsTheConnectionOpen() async throws {
    let peer = StubPeer(sendError: .sendQueueFull)
    let connection = NetherNetConnection(networkID: 1, connectionID: 2, signaling: StubSignaling(), peer: peer)
    try await connection.start()
    peer.open()
    try await connection.waitForHTTPChannels(until: .now.advanced(by: .seconds(1)))
    await #expect(throws: ConnectionError.sendQueueFull) { try await connection.send([42]) }
    #expect(await connection.isOpen)
    await connection.close()
}

private struct StubSignaling: NetherNetSignaling {
    func send(_ signal: Signal, to networkID: UInt64) async throws {}
}

private struct StubPeer: WebRTCPeer {
    private let stream = AsyncStream<PeerEvent>.makeStream()
    var sendError: ConnectionError?
    var events: AsyncStream<PeerEvent> { stream.stream }

    func offer() throws {}
    func remoteDescription(_ sdp: String, kind: Signal.Kind) throws {}
    func remoteCandidate(_ candidate: String) throws {}
    func send(_ segments: [[UInt8]], on channel: DataChannel) throws { if let sendError { throw sendError } }
    func open() {
        stream.continuation.yield(.open(.reliable))
        stream.continuation.yield(.open(.unreliable))
    }
    func deliver(_ message: [UInt8], on channel: DataChannel) {
        stream.continuation.yield(.message(channel, [0] + message))
    }
    func close() { stream.continuation.finish() }
    func fail(_ failure: WebRTCError) { stream.continuation.yield(.failed(failure)) }
}

@Test(.timeLimit(.minutes(1))) func unreliableInboxTrafficLeavesRoomForReliableMessages() async throws {
    let peer = StubPeer()
    let connection = NetherNetConnection(networkID: 1, connectionID: 2, signaling: StubSignaling(), peer: peer)
    try await connection.start()
    peer.open()
    for value in 0..<64 {
        peer.deliver([UInt8(value)], on: .unreliable)
    }
    peer.deliver([255], on: .reliable)
    peer.close()

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await connection.isClosed), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(await connection.isClosed)

    var iterator = connection.messages.makeAsyncIterator()
    var values: [UInt8] = []
    while let message = try await iterator.next() {
        values += message
    }
    #expect(values == (0..<32).map(UInt8.init) + [255])
}
