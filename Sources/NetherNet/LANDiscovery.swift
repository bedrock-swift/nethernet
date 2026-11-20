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
    private var endpoints: [UInt64: Endpoint] = [:]

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

    public func endpoint(for networkID: UInt64) -> Endpoint? { endpoints[networkID] }

    public mutating func receive(_ datagram: [UInt8], from endpoint: Endpoint) throws -> Input {
        let packet = try DiscoveryPacket(decoding: datagram)
        guard packet.sender != networkID else { return Input() }
        switch packet.body {
        case .request:
            if endpoints[packet.sender] == nil { learn(packet.sender, at: endpoint) }
            guard let advertisement else { return Input() }
            return Input(reply: try DiscoveryPacket(sender: networkID, body: .response(advertisement)).encode())
        case let .response(payload):
            learn(packet.sender, at: endpoint)
            return Input(event: .advertisement(networkID: packet.sender, payload: payload, from: endpoint))
        case let .ping(recipient):
            if recipient == networkID, endpoints[packet.sender] == nil { learn(packet.sender, at: endpoint) }
            return Input()
        case let .message(recipient, signal):
            guard recipient == networkID else { return Input() }
            if let known = endpoints[packet.sender], known != endpoint { return Input() }
            learn(packet.sender, at: endpoint)
            return Input(event: .signal(signal, networkID: packet.sender, from: endpoint))
        }
    }

    private mutating func learn(_ networkID: UInt64, at endpoint: Endpoint) {
        if endpoints[networkID] == nil, endpoints.count == 1024, let first = endpoints.keys.first {
            endpoints.removeValue(forKey: first)
        }
        endpoints[networkID] = endpoint
    }
}
