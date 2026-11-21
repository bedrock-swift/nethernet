import Foundation
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

@Test func httpListenerRequiresAnIdentityBeforeCreatingAPeerWhenVerificationIsEnabled() async throws {
    let listener = try NetherNetHTTPListener(identity: HTTPJoinIdentity(verify: { _, _ in })) {
        throw ConnectionError.invalidSignal
    }
    await #expect(throws: SDPIdentityError.missing) {
        try await listener.answer("offer", from: 42)
    }
    await listener.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func httpListenerCountsVerificationAgainstAdmission(perSource: Bool) async throws {
    let entered = AsyncStream<Void>.makeStream()
    let unblock = AsyncStream<Void>.makeStream()
    let verifier = HTTPJoinIdentity(verify: { _, _ in
        entered.continuation.yield(())
        for await _ in unblock.stream { break }
    })
    let listener = try NetherNetHTTPListener(
        maximumConnections: perSource ? 2 : 1, maximumConnectionsPerSource: 1, identity: verifier
    ) { AnsweringPeer() }
    let peer = try SDPIdentity(domain: "test", token: "e30.e30.AA", fingerprintSignature: "e30..AA")
    let offer = try peer.adding(to: "v=0\r\na=fingerprint:sha-256 AB:CD\r\n")
    let source: HTTPJoinSource = perSource ? .ipv4(0x7f000001) : .unlimited
    let first = Task { try await listener.answer(offer, from: 1, source: source) }
    defer {
        unblock.continuation.finish()
        first.cancel()
    }
    var events = entered.stream.makeAsyncIterator()
    _ = await events.next()
    await #expect(throws: HTTPJoinError.tooManyConnections) {
        try await listener.answer(offer, from: 2, source: source)
    }
    await listener.close()
    unblock.continuation.finish()
    await #expect(throws: ConnectionError.closed) { try await first.value }
}

@Test func httpHandlerRoutesStatusAndJoin() async throws {
    let listener = try NetherNetHTTPListener { AnsweringPeer() }
    let status = HTTPServerStatus(
        name: "Server", world: "World", protocolVersion: 819, version: "1.21.94",
        players: 1, capacity: 8, gameMode: 0
    )
    let handler = NetherNetHTTPHandler(listener: listener, status: status)
    let statusResponse = await handler.handle(method: "GET", path: "/v1/join?version=1.26.60&protocol=2225&id=42", source: .unlimited)
    #expect(statusResponse.statusCode == 200)
    #expect(statusResponse.contentType == "application/json")
    #expect(try JSONDecoder().decode(HTTPServerStatus.self, from: statusResponse.body) == status)

    let malformed = await handler.handle(
        method: "POST", path: "/v1/join/+42?version=1.26.60", body: Data("offer".utf8), source: .unlimited
    )
    #expect(malformed.statusCode == 400)
    let answer = await handler.handle(
        method: "POST", path: "/v1/join/42?version=1.26.60", body: Data("offer".utf8), source: .unlimited
    )
    #expect(answer.statusCode == 200)
    #expect(answer.contentType == "application/sdp")
    #expect(answer.body == Data("answer".utf8))
    await handler.close()
}

@Test func httpJoinLimitsIPv6PrefixesAndMappedIPv4Sources() async throws {
    let listener = try NetherNetHTTPListener(maximumConnections: 4, maximumConnectionsPerSource: 1) { AnsweringPeer() }
    let handler = NetherNetHTTPHandler(listener: listener)
    let offer = Data("offer".utf8)
    let first = await handler.handle(method: "POST", path: "/v1/join/1", body: offer, source: .ipv6(high: 1, low: 1))
    let same = await handler.handle(method: "POST", path: "/v1/join/2", body: offer, source: .ipv6(high: 1, low: 2))
    let other = await handler.handle(method: "POST", path: "/v1/join/3", body: offer, source: .ipv6(high: 2, low: 1))
    let v4 = await handler.handle(method: "POST", path: "/v1/join/4", body: offer, source: .ipv4(0x7f000001))
    let mapped = await handler.handle(
        method: "POST", path: "/v1/join/5", body: offer, source: .ipv6(high: 0, low: 0xffff_7f00_0001)
    )
    #expect([first, same, other, v4, mapped].map(\.statusCode) == [200, 503, 200, 200, 503])
    await handler.close()
}
