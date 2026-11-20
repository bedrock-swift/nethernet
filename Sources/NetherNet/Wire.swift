enum WireError: Error, Equatable {
    case malformed
    case tooLarge
    case checksum
}

struct WireReader {
    private var bytes: ArraySlice<UInt8>

    init(_ bytes: [UInt8]) {
        self.bytes = bytes[...]
    }

    var isEmpty: Bool { bytes.isEmpty }

    mutating func read(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.count else { throw WireError.malformed }
        let prefix = bytes.prefix(count)
        bytes = bytes.dropFirst(count)
        return prefix
    }

    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let field = try read(MemoryLayout<T>.size)
        return field.enumerated().reduce(0) { $0 | (T(truncatingIfNeeded: $1.element) << ($1.offset * 8)) }
    }

    mutating func varUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, through: 28, by: 7) {
            let byte = try integer(UInt8.self)
            guard shift != 28 || byte <= 0x0f else { throw WireError.malformed }
            value |= UInt32(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
        }
        throw WireError.malformed
    }

    mutating func varInt32() throws -> Int32 {
        let value = try varUInt32()
        return Int32(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
    }

    mutating func string(variableLength: Bool = false) throws -> String {
        let count = try variableLength ? varUInt32() : UInt32(integer(UInt8.self))
        guard let size = Int(exactly: count),
              let value = String(validating: try read(size), as: UTF8.self) else { throw WireError.malformed }
        return value
    }
}

extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendVarUInt32(_ value: UInt32) {
        var value = value
        while value >= 0x80 {
            append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        append(UInt8(value))
    }

    mutating func appendVarInt32(_ value: Int32) {
        appendVarUInt32((UInt32(bitPattern: value) << 1) ^ UInt32(bitPattern: value >> 31))
    }

    mutating func appendString(_ value: String, variableLength: Bool = false) throws {
        let length = value.utf8.count
        if variableLength {
            guard let count = UInt32(exactly: length) else { throw WireError.tooLarge }
            appendVarUInt32(count)
        } else {
            guard let count = UInt8(exactly: length) else { throw WireError.tooLarge }
            append(count)
        }
        append(contentsOf: value.utf8)
    }
}
