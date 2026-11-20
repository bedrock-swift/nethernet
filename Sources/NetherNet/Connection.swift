public enum DataChannel: String, Hashable, Sendable {
    case reliable = "ReliableDataChannel"
    case unreliable = "UnreliableDataChannel"
}

public enum PeerEvent: Sendable {
    case description(Signal.Kind, String)
    case candidate(String)
    case open(DataChannel)
    case message(DataChannel, [UInt8])
    case closed
}

public protocol WebRTCPeer: Sendable {
    var events: AsyncStream<PeerEvent> { get }
    func offer() throws
    func remoteDescription(_ sdp: String, kind: Signal.Kind) throws
    func remoteCandidate(_ candidate: String) throws
    func send(_ segments: [[UInt8]], on channel: DataChannel) throws
    func close()
}

public enum ConnectionError: Error, Equatable {
    case invalidSignal
    case remoteError(String)
    case notOpen
    case closed
    case overflow
}

public actor NetherNetConnection {
    public nonisolated let networkID: UInt64
    public nonisolated let connectionID: UInt64
    public nonisolated let messages: AsyncThrowingStream<[UInt8], any Error>

    private let peer: any WebRTCPeer
    private let signaling: any NetherNetSignaling
    private let output: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private var worker: Task<Void, Never>?
    private var opened: Set<DataChannel> = []
    private var incoming = MessageCodec()
    private var localDescriptionSent = false
    private var receivedDescription = false
    private var localCandidates: [String] = []
    private var remoteCandidates: [String] = []
    private var closed = false

    public init(networkID: UInt64, connectionID: UInt64, signaling: any NetherNetSignaling, peer: any WebRTCPeer) {
        self.networkID = networkID
        self.connectionID = connectionID
        self.signaling = signaling
        self.peer = peer
        let stream = AsyncThrowingStream<[UInt8], any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        messages = stream.stream
        output = stream.continuation
    }

    deinit {
        worker?.cancel()
        output.finish()
        peer.close()
    }

    public var isClosed: Bool { closed }
    public var isOpen: Bool { !closed && opened.count == 2 }

    public func start() throws {
        guard !closed, worker == nil else { throw ConnectionError.invalidSignal }
        observe()
        do { try peer.offer() } catch {
            finish(error)
            throw error
        }
    }

    public func receive(_ signal: Signal) throws {
        guard !closed else { throw ConnectionError.closed }
        guard signal.connectionID == connectionID else { throw ConnectionError.invalidSignal }
        observe()
        do {
            switch signal.kind {
            case .offer, .answer:
                guard !receivedDescription else { return }
                try peer.remoteDescription(signal.data, kind: signal.kind)
                receivedDescription = true
                for candidate in remoteCandidates { try peer.remoteCandidate(candidate) }
                remoteCandidates.removeAll()
            case .candidate:
                if receivedDescription {
                    try peer.remoteCandidate(signal.data)
                } else {
                    guard remoteCandidates.count < 128 else { throw ConnectionError.overflow }
                    remoteCandidates.append(signal.data)
                }
            case .error:
                throw ConnectionError.remoteError(signal.data)
            }
        } catch {
            finish(error)
            throw error
        }
    }

    public func send(_ payload: [UInt8], on channel: DataChannel = .reliable) throws {
        guard isOpen else { throw ConnectionError.notOpen }
        let segments = try MessageCodec.encode(payload, reliable: channel == .reliable)
        do { try peer.send(segments, on: channel) } catch {
            finish(error)
            throw error
        }
    }

    public func close() {
        finish()
    }

    private func observe() {
        guard worker == nil else { return }
        let events = peer.events
        worker = Task { [weak self] in
            for await event in events { await self?.handle(event) }
            await self?.finish()
        }
    }

    private func handle(_ event: PeerEvent) async {
        guard !closed else { return }
        do {
            switch event {
            case let .description(kind, sdp):
                try await signal(kind, data: sdp)
                localDescriptionSent = true
                for candidate in localCandidates { try await signal(.candidate, data: candidate) }
                localCandidates.removeAll()
            case let .candidate(candidate):
                if localDescriptionSent {
                    try await signal(.candidate, data: candidate)
                } else {
                    guard localCandidates.count < 128 else { throw ConnectionError.overflow }
                    localCandidates.append(candidate)
                }
            case let .open(channel):
                opened.insert(channel)
            case let .message(channel, bytes):
                if let message = try incoming.receive(bytes, reliable: channel == .reliable),
                   case .dropped = output.yield(message) {
                    throw ConnectionError.overflow
                }
            case .closed:
                finish()
            }
        } catch {
            finish(error)
        }
    }

    private func signal(_ kind: Signal.Kind, data: String) async throws {
        try await signaling.send(Signal(kind: kind, connectionID: connectionID, data: data), to: networkID)
    }

    private func finish(_ error: (any Error)? = nil) {
        guard !closed else { return }
        closed = true
        worker?.cancel()
        output.finish(throwing: error)
        peer.close()
    }
}
