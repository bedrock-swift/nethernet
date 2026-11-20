public actor NetherNetHTTPListener {
    public nonisolated let connections: AsyncStream<NetherNetConnection>

    private let output: AsyncStream<NetherNetConnection>.Continuation
    private let peerFactory: @Sendable () throws -> any WebRTCPeer
    private let identity: HTTPJoinIdentity
    private let maximumConnections: Int
    private var sessions: [UInt64: NetherNetConnection] = [:]
    private var closed = false
    private var verifying = 0

    public init(
        library: LibDataChannel, maximumConnections: Int = 64, identity: HTTPJoinIdentity = .init()
    ) throws {
        try self.init(maximumConnections: maximumConnections, identity: identity) { try library.makePeer(trickleICE: false) }
    }

    public init(
        maximumConnections: Int = 64, identity: HTTPJoinIdentity = .init(),
        peerFactory: @escaping @Sendable () throws -> any WebRTCPeer
    ) throws {
        guard maximumConnections > 0 else { throw HTTPJoinError.invalidConnectionLimit }
        let stream = AsyncStream<NetherNetConnection>.makeStream(bufferingPolicy: .bufferingOldest(maximumConnections))
        connections = stream.stream
        output = stream.continuation
        self.peerFactory = peerFactory
        self.maximumConnections = maximumConnections
        self.identity = identity
    }

    deinit { output.finish() }

    public func answer(_ offer: String, from networkID: UInt64, timeout: Duration = .seconds(15)) async throws -> String {
        guard !offer.isEmpty else { throw HTTPJoinError.invalidOffer }
        guard offer.utf8.count <= maximumHTTPJoinBody else { throw HTTPJoinError.bodyTooLarge }
        guard timeout > .zero else { throw HTTPJoinError.timedOut }
        try Task.checkCancellation()

        for (id, connection) in sessions {
            if await connection.isClosed { sessions.removeValue(forKey: id) }
        }
        guard !closed else { throw ConnectionError.closed }
        guard sessions.count + verifying < maximumConnections else { throw HTTPJoinError.tooManyConnections }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        verifying += 1
        do {
            try await identity.validateRemote(offer)
        } catch {
            verifying -= 1
            throw error
        }
        verifying -= 1
        try Task.checkCancellation()
        guard !closed else { throw ConnectionError.closed }
        guard .now < deadline else { throw HTTPJoinError.timedOut }

        var id = UInt64.random(in: 1...UInt64.max)
        while sessions[id] != nil { id = .random(in: 1...UInt64.max) }
        let exchange = HTTPAnswerExchange(identity: identity)
        let connection = NetherNetConnection(networkID: networkID, connectionID: id, signaling: exchange, peer: try peerFactory())
        sessions[id] = connection
        do {
            try await connection.receive(Signal(kind: .offer, connectionID: id, data: offer))
            let sdp = try await waitForAnswer(exchange, connection: connection, until: deadline)
            Task { [weak self] in await self?.publish(connection, until: deadline) }
            return sdp
        } catch {
            await remove(connection)
            throw error
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        output.finish()
        let active = Array(sessions.values)
        sessions.removeAll()
        for connection in active { await connection.close() }
    }

    private func waitForAnswer(
        _ exchange: HTTPAnswerExchange, connection: NetherNetConnection, until deadline: ContinuousClock.Instant
    ) async throws -> String {
        while true {
            try Task.checkCancellation()
            _ = try await connection.checkOpen()
            let answer = await exchange.answer
            guard !closed else { throw ConnectionError.closed }
            if let answer { return answer }
            guard ContinuousClock.now < deadline else { throw HTTPJoinError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func publish(_ connection: NetherNetConnection, until deadline: ContinuousClock.Instant) async {
        do {
            try await connection.waitForHTTPChannels(until: deadline)
            guard !closed, case .enqueued = output.yield(connection) else { throw ConnectionError.closed }
        } catch {
            await remove(connection)
        }
    }

    private func remove(_ connection: NetherNetConnection) async {
        sessions.removeValue(forKey: connection.connectionID)
        await connection.close()
    }
}

private actor HTTPAnswerExchange: NetherNetSignaling {
    private let identity: HTTPJoinIdentity
    private(set) var answer: String?

    init(identity: HTTPJoinIdentity) { self.identity = identity }

    func send(_ signal: Signal, to networkID: UInt64) throws {
        guard signal.kind == .answer, answer == nil else { throw ConnectionError.invalidSignal }
        guard !signal.data.isEmpty else { throw HTTPJoinError.invalidAnswer }
        let sdp = try identity.localDescription(signal.data)
        guard sdp.utf8.count <= maximumHTTPJoinBody else { throw HTTPJoinError.bodyTooLarge }
        answer = sdp
    }
}

extension NetherNetConnection {
    func waitForHTTPChannels(until deadline: ContinuousClock.Instant) async throws {
        while true {
            try Task.checkCancellation()
            if try checkOpen() { return }
            guard ContinuousClock.now < deadline else { throw HTTPJoinError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
