import CryptoSwift

public struct DiscoveryPacket: Equatable, Sendable {
    public static let port: UInt16 = 7551

    public enum Body: Equatable, Sendable {
        case request
        case response([UInt8])
        case message(recipient: UInt64, Signal)
        case ping(recipient: UInt64)
    }

    public let sender: UInt64
    public let body: Body

    public init(sender: UInt64, body: Body) {
        self.sender = sender
        self.body = body
    }

    private static let key: [UInt8] = {
        var applicationID: [UInt8] = []
        applicationID.appendLE(UInt64(0xdeadbeef))
        return applicationID.sha256()
    }()

    public func encode() throws -> [UInt8] {
        var packet: [UInt8] = []
        switch body {
        case .request: packet.appendLE(UInt16(0))
        case .response: packet.appendLE(UInt16(1))
        case .message, .ping: packet.appendLE(UInt16(2))
        }
        packet.appendLE(sender)
        packet += [UInt8](repeating: 0, count: 8)
        switch body {
        case .request:
            break
        case let .response(data):
            guard data.count <= (65_440 - 22) / 2 else { throw WireError.tooLarge }
            let digits = Array("0123456789abcdef".utf8)
            packet.appendLE(UInt32(data.count * 2))
            for byte in data {
                packet += [digits[Int(byte >> 4)], digits[Int(byte & 15)]]
            }
        case let .message(recipient, signal):
            let data = signal.text.utf8
            guard data.count <= 65_440 - 30 else { throw WireError.tooLarge }
            packet.appendLE(recipient)
            packet.appendLE(UInt32(data.count))
            packet.append(contentsOf: data)
        case let .ping(recipient):
            packet.appendLE(recipient)
            packet.appendLE(UInt32(4))
            packet.append(contentsOf: "Ping".utf8)
        }
        var payload: [UInt8] = []
        payload.appendLE(UInt16(packet.count))
        payload += packet
        let tag = try HMAC(key: Self.key, variant: .sha2(.sha256)).authenticate(payload)
        let cipher = try AES(key: Self.key, blockMode: ECB(), padding: .pkcs7)
        return tag + (try cipher.encrypt(payload))
    }

    public init(decoding datagram: [UInt8]) throws {
        guard (48...65_507).contains(datagram.count), datagram.count % 16 == 0 else { throw WireError.malformed }
        let cipher = try AES(key: Self.key, blockMode: ECB(), padding: .pkcs7)
        let payload = try cipher.decrypt(Array(datagram.dropFirst(32)))
        let tag = try HMAC(key: Self.key, variant: .sha2(.sha256)).authenticate(payload)
        let mismatch = zip(datagram.prefix(32), tag).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard mismatch == 0 else { throw WireError.checksum }

        var outer = WireReader(payload)
        let size = try outer.integer(UInt16.self)
        guard Int(size) <= payload.count else { throw WireError.malformed }
        var packet = outer
        let id = try packet.integer(UInt16.self)
        let normalLength = Int(size) == payload.count || Int(size) == payload.count - 2
        guard normalLength || id == 2 else { throw WireError.malformed }
        sender = try packet.integer(UInt64.self)
        _ = try packet.read(8)
        switch id {
        case 0:
            body = .request
        case 1:
            let bytes = try Self.field(from: &packet)
            guard bytes.count % 2 == 0 else { throw WireError.malformed }
            var iterator = bytes.makeIterator()
            var data: [UInt8] = []
            while let high = iterator.next(), let low = iterator.next() {
                data.append(try (Self.nibble(high) << 4) | Self.nibble(low))
            }
            body = .response(data)
        case 2:
            let recipient = try packet.integer(UInt64.self)
            let declared = try packet.integer(UInt32.self)
            let actual = payload.count - 32
            let capped = declared == 1_140 && actual > 1_140 && size == 1_172
            guard actual >= 0, (normalLength && actual == Int(declared)) || capped,
                  let text = String(validating: try packet.read(actual), as: UTF8.self) else {
                throw WireError.malformed
            }
            body = text == "Ping" ? .ping(recipient: recipient) : .message(recipient: recipient, try Signal(parsing: text))
        default:
            throw WireError.malformed
        }
        guard packet.isEmpty else { throw WireError.malformed }
    }

    private static func field(from reader: inout WireReader) throws -> ArraySlice<UInt8> {
        let size = try reader.integer(UInt32.self)
        return try reader.read(Int(size))
    }

    private static func nibble(_ value: UInt8) throws -> UInt8 {
        switch value {
        case 48...57: value - 48
        case 65...70: value - 55
        case 97...102: value - 87
        default: throw WireError.malformed
        }
    }
}
