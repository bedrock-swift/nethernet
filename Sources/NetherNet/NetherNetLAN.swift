import Dispatch
import Foundation

public struct LANAdvertisement: Equatable, Sendable {
    public let networkID: UInt64
    public let address: LANAddress
    public let data: [UInt8]
}

public enum LANError: Error, Equatable {
    case unknownPeer
    case timedOut
    case tooManyConnections
}

public actor NetherNetLAN {
    public nonisolated let localAddress: LANAddress
    public nonisolated let networkID: UInt64
    public nonisolated let advertisements: AsyncStream<LANAdvertisement>
    public nonisolated let connections: AsyncStream<NetherNetConnection>

    private struct Key: Hashable {
        let network: UInt64
        let connection: UInt64
    }

    private struct EarlyCandidates {
        let sender: LANAddress
        let expires: ContinuousClock.Instant
        var signals: [Signal] = []
    }

    private struct PendingSignal {
        let bytes: [UInt8]
        let interval: Duration
        var due: ContinuousClock.Instant
        var retries = 3
    }

    private struct Signaling: NetherNetSignaling {
        weak var transport: NetherNetLAN?

        func send(_ signal: Signal, to networkID: UInt64) async throws {
            guard let transport else { throw ConnectionError.closed }
            try await transport.send(signal, to: networkID)
        }
    }

    private let socket: LANSocket
    private let peerFactory: @Sendable () throws -> any WebRTCPeer
    private let advertising: AsyncStream<LANAdvertisement>.Continuation
    private let accepting: AsyncStream<NetherNetConnection>.Continuation
    private let gate = ReceiveGate()
    private var discovery: LANDiscovery<LANAddress>
    private var sessions: [Key: NetherNetConnection] = [:]
    private var pendingSignals: [Key: [PendingSignal]] = [:]
    private var earlyCandidates: [Key: EarlyCandidates] = [:]
    private var worker: Task<Void, Never>?
    private var closed = false

    public init(
        on address: LANAddress,
        networkID: UInt64 = .random(in: 1...UInt64.max),
        advertisement: [UInt8]? = nil,
        peerFactory: @escaping @Sendable () throws -> any WebRTCPeer
    ) throws {
        socket = try LANSocket(bindTo: address)
        localAddress = socket.localAddress
        self.networkID = networkID
        self.peerFactory = peerFactory
        discovery = LANDiscovery(networkID: networkID, advertisement: advertisement)
        let ads = AsyncStream<LANAdvertisement>.makeStream(bufferingPolicy: .bufferingNewest(128))
        advertisements = ads.stream
        advertising = ads.continuation
        let peers = AsyncStream<NetherNetConnection>.makeStream(bufferingPolicy: .bufferingOldest(32))
        connections = peers.stream
        accepting = peers.continuation
    }

    deinit {
        gate.stop()
        worker?.cancel()
        advertising.finish()
        accepting.finish()
    }

    public func start() {
        guard !closed, worker == nil else { return }
        typealias Packet = (bytes: [UInt8], sender: LANAddress)
        let stream = AsyncStream<Packet>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let socket = self.socket
        let gate = self.gate
        DispatchQueue(label: "nethernet.lan").async {
            defer { stream.continuation.finish() }
            var buffer = [UInt8](repeating: 0, count: 65_507)
            while gate.isRunning {
                do {
                    if let received = try socket.receive(into: &buffer) {
                        _ = stream.continuation.yield(received)
                    }
                } catch { return }
            }
        }
        worker = Task { [weak self] in
            for await packet in stream.stream { await self?.receive(packet.bytes, from: packet.sender) }
            await self?.close()
        }
    }

    public func discover(at endpoint: LANAddress = .broadcast) throws {
        guard !closed else { throw ConnectionError.closed }
        start()
        try socket.send(discovery.request(), to: endpoint)
    }

    public func connect(to remoteID: UInt64, timeout: Duration = .seconds(8)) async throws -> NetherNetConnection {
        guard !closed else { throw ConnectionError.closed }
        guard timeout > .zero else { throw LANError.timedOut }
        guard discovery.endpoint(for: remoteID) != nil else { throw LANError.unknownPeer }
        start()
        await prune()
        guard sessions.count < 64 else { throw LANError.tooManyConnections }
        let key = Key(network: remoteID, connection: .random(in: 1...UInt64.max))
        let connection = try create(key)
        sessions[key] = connection
        pendingSignals[key] = []
        do {
            try await connection.start()
            try await waitForOpen(connection, key: key, timeout: timeout)
            return connection
        } catch {
            removeSession(key)
            await connection.close()
            throw error
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        gate.stop()
        worker?.cancel()
        advertising.finish()
        accepting.finish()
        let active = Array(sessions.values)
        sessions.removeAll()
        earlyCandidates.removeAll()
        pendingSignals.removeAll()
        for connection in active { await connection.close() }
    }

    private func send(_ signal: Signal, to remoteID: UInt64) throws {
        guard !closed else { throw ConnectionError.closed }
        guard let endpoint = discovery.endpoint(for: remoteID) else { throw LANError.unknownPeer }
        let bytes = try discovery.message(signal, to: remoteID)
        try socket.send(bytes, to: endpoint)
        let key = Key(network: remoteID, connection: signal.connectionID)
        guard let count = pendingSignals[key]?.count, count < 130 else { return }
        let interval: Duration = signal.kind == .offer ? .seconds(2) : .milliseconds(500)
        pendingSignals[key]?.append(PendingSignal(bytes: bytes, interval: interval, due: .now.advanced(by: interval)))
    }

    private func receive(_ bytes: [UInt8], from sender: LANAddress) async {
        guard !closed, let input = try? discovery.receive(bytes, from: sender) else { return }
        if let reply = input.reply { try? socket.send(reply, to: sender) }
        switch input.event {
        case let .advertisement(id, data, address):
            _ = advertising.yield(LANAdvertisement(networkID: id, address: address, data: data))
        case let .signal(signal, id, sender):
            let key = Key(network: id, connection: signal.connectionID)
            if let connection = sessions[key] {
                try? await connection.receive(signal)
            } else if signal.kind == .offer, discovery.advertisement != nil {
                await accept(signal, from: sender, key: key)
            } else if signal.kind == .candidate {
                bufferCandidate(signal, from: sender, key: key)
            }
        case nil:
            break
        }
    }

    private func bufferCandidate(_ signal: Signal, from sender: LANAddress, key: Key) {
        let now = ContinuousClock.now
        if let current = earlyCandidates[key], current.sender != sender || current.expires <= now {
            earlyCandidates.removeValue(forKey: key)
        }
        if earlyCandidates[key] == nil, earlyCandidates.count >= 64 {
            earlyCandidates = earlyCandidates.filter { now < $0.value.expires }
            guard earlyCandidates.count < 64 else { return }
        }
        var entry = earlyCandidates[key] ?? EarlyCandidates(sender: sender, expires: now.advanced(by: .seconds(8)))
        guard entry.signals.count < 16, !entry.signals.contains(signal) else { return }
        entry.signals.append(signal)
        earlyCandidates[key] = entry
    }

    private func accept(_ offer: Signal, from sender: LANAddress, key: Key) async {
        await prune()
        guard !closed, sessions.count < 64, let connection = try? create(key) else { return }
        sessions[key] = connection
        pendingSignals[key] = []
        do {
            try await connection.receive(offer)
            if let entry = earlyCandidates.removeValue(forKey: key), entry.sender == sender, .now < entry.expires {
                for signal in entry.signals { try await connection.receive(signal) }
            }
        } catch {
            removeSession(key)
            await connection.close()
            return
        }
        Task { [weak self] in
            await self?.publish(connection, key: key)
        }
    }

    private func publish(_ connection: NetherNetConnection, key: Key) async {
        do {
            try await waitForOpen(connection, key: key, timeout: .seconds(8))
            switch accepting.yield(connection) {
            case .dropped, .terminated: throw ConnectionError.overflow
            case .enqueued: break
            @unknown default: throw ConnectionError.overflow
            }
        } catch {
            removeSession(key)
            await connection.close()
        }
    }

    private func prune() async {
        for (key, connection) in sessions {
            if await connection.isClosed { removeSession(key) }
        }
    }

    private func removeSession(_ key: Key) {
        sessions.removeValue(forKey: key)
        pendingSignals.removeValue(forKey: key)
    }

    private func create(_ key: Key) throws -> NetherNetConnection {
        try NetherNetConnection(
            networkID: key.network, connectionID: key.connection,
            signaling: Signaling(transport: self), peer: peerFactory()
        )
    }

    private func resendSignals(for key: Key, now: ContinuousClock.Instant) {
        guard var pending = pendingSignals[key], pending.contains(where: { $0.due <= now }),
              let endpoint = discovery.endpoint(for: key.network) else { return }
        for index in pending.indices where pending[index].due <= now {
            try? socket.send(pending[index].bytes, to: endpoint)
            pending[index].retries -= 1
            pending[index].due = now.advanced(by: pending[index].interval)
        }
        pending.removeAll { $0.retries == 0 }
        pendingSignals[key] = pending
    }

    private func waitForOpen(_ connection: NetherNetConnection, key: Key, timeout: Duration) async throws {
        defer { pendingSignals.removeValue(forKey: key) }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            guard !closed else { throw ConnectionError.closed }
            if try await connection.checkOpen() { return }
            let now = ContinuousClock.now
            guard now < deadline else { throw LANError.timedOut }
            resendSignals(for: key, now: now)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ReceiveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    var isRunning: Bool { lock.withLock { running } }
    func stop() { lock.withLock { running = false } }
}
