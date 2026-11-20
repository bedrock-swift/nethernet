public struct MessageCodec: Sendable {
    public static let segmentSize = 10_000
    static let maximumIncomingSegment = 262_143
    public static let maximumSize = 255 * segmentSize

    private var remaining: UInt8?
    private var payload: [UInt8] = []

    public init() {}

    public static func encode(_ payload: [UInt8], reliable: Bool = true) throws -> [[UInt8]] {
        guard !payload.isEmpty, payload.count <= (reliable ? maximumSize : segmentSize) else { throw WireError.tooLarge }
        let count = (payload.count + segmentSize - 1) / segmentSize
        return (0..<count).map { segment in
            let start = segment * segmentSize
            let end = min(start + segmentSize, payload.count)
            return [UInt8(count - segment - 1)] + payload[start..<end]
        }
    }

    public mutating func receive(_ segment: [UInt8], reliable: Bool = true) throws -> [UInt8]? {
        guard (2...Self.maximumIncomingSegment + 1).contains(segment.count),
              let count = segment.first, count < 255 else { throw WireError.malformed }
        if !reliable {
            guard count == 0 else { throw WireError.malformed }
            return Array(segment.dropFirst())
        }
        guard remaining.map({ $0 == count }) ?? true,
              payload.count + segment.count - 1 <= Self.maximumSize else { throw WireError.malformed }
        payload.append(contentsOf: segment.dropFirst())
        remaining = count == 0 ? nil : count - 1
        guard count == 0 else { return nil }
        let message = payload
        payload = []
        return message
    }
}
