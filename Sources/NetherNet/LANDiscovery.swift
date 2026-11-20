public struct LANDiscovery<Endpoint: Hashable & Sendable>: Sendable {
    public enum Event: Equatable, Sendable {
        case advertisement(networkID: UInt64, payload: [UInt8], from: Endpoint)
        case signal(Signal, networkID: UInt64, from: Endpoint)
    }

    public struct Input: Sendable {
        public fileprivate(set) var reply: [UInt8]?
        public fileprivate(set) var event: Event?
    }

    public let networkID: UInt64
    public var advertisement: [UInt8]?
    private struct Route: Sendable {
        let endpoint: Endpoint
        let lastSeen: ContinuousClock.Instant

        func isCurrent(at now: ContinuousClock.Instant) -> Bool {
            now < lastSeen.advanced(by: .seconds(15))
        }
    }

    private var routes: [UInt64: Route] = [:]

    public init(networkID: UInt64 = .random(in: 1...UInt64.max), advertisement: [UInt8]? = nil) {
        self.networkID = networkID
        self.advertisement = advertisement
    }

    public func request() throws -> [UInt8] {
        try DiscoveryPacket(sender: networkID, body: .request).encode()
    }

    public func message(_ signal: Signal, to recipient: UInt64) throws -> [UInt8] {
        try DiscoveryPacket(sender: networkID, body: .message(recipient: recipient, signal)).encode()
    }

    public func endpoint(for networkID: UInt64, at now: ContinuousClock.Instant = .now) -> Endpoint? {
        guard let route = routes[networkID], route.isCurrent(at: now) else { return nil }
        return route.endpoint
    }

    public mutating func receive(
        _ datagram: [UInt8], from endpoint: Endpoint, at now: ContinuousClock.Instant = .now
    ) throws -> Input {
        let packet = try DiscoveryPacket(decoding: datagram)
        guard packet.sender != networkID else { return Input() }
        switch packet.body {
        case .request:
            guard learn(packet.sender, at: endpoint, now: now), let advertisement else { return Input() }
            return Input(reply: try DiscoveryPacket(sender: networkID, body: .response(advertisement)).encode())
        case let .response(payload):
            guard learn(packet.sender, at: endpoint, now: now) else { return Input() }
            return Input(event: .advertisement(networkID: packet.sender, payload: payload, from: endpoint))
        case let .ping(recipient):
            if recipient == networkID { _ = learn(packet.sender, at: endpoint, now: now) }
            return Input()
        case let .message(recipient, signal):
            guard recipient == networkID, learn(packet.sender, at: endpoint, now: now) else { return Input() }
            return Input(event: .signal(signal, networkID: packet.sender, from: endpoint))
        }
    }

    private mutating func learn(_ networkID: UInt64, at endpoint: Endpoint, now: ContinuousClock.Instant) -> Bool {
        if let known = self.endpoint(for: networkID, at: now), known != endpoint { return false }
        if routes[networkID] == nil, routes.count == 1024,
           let oldest = routes.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
            routes.removeValue(forKey: oldest.key)
        }
        routes[networkID] = Route(endpoint: endpoint, lastSeen: now)
        return true
    }
}
