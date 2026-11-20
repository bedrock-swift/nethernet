import NetherNet
import Testing

@Test(.timeLimit(.minutes(1))) func httpListenerAnswersAndPublishesAnOpenConnection() async throws {
    let listener = try NetherNetHTTPListener(maximumConnections: 1) { AnsweringPeer() }
    let answer = try await listener.answer("offer", from: 42, timeout: .seconds(1))
    #expect(answer == "answer")

    var incoming = listener.connections.makeAsyncIterator()
    let connection = try #require(await incoming.next())
    #expect(connection.networkID == 42)
    #expect(await connection.isOpen)
    await #expect(throws: HTTPJoinError.tooManyConnections) {
        try await listener.answer("offer", from: 43)
    }
    await listener.close()
    #expect(await connection.isClosed)
}

private struct AnsweringPeer: WebRTCPeer {
    private let stream = AsyncStream<PeerEvent>.makeStream()
    var events: AsyncStream<PeerEvent> { stream.stream }

    func offer() throws { throw ConnectionError.invalidSignal }

    func remoteDescription(_ sdp: String, kind: Signal.Kind) throws {
        guard kind == .offer, sdp == "offer" else { throw ConnectionError.invalidSignal }
        stream.continuation.yield(.description(.answer, "answer"))
        stream.continuation.yield(.open(.reliable))
        stream.continuation.yield(.open(.unreliable))
    }

    func remoteCandidate(_ candidate: String) throws {}
    func send(_ segments: [[UInt8]], on channel: DataChannel) throws {}
    func close() { stream.continuation.finish() }
}
