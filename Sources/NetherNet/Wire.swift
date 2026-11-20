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

    mutating func string() throws -> String {
        let count = try integer(UInt8.self)
        guard let value = String(validating: try read(Int(count)), as: UTF8.self) else { throw WireError.malformed }
        return value
    }
}

extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendString(_ value: String) throws {
        guard let count = UInt8(exactly: value.utf8.count) else { throw WireError.tooLarge }
        append(count)
        append(contentsOf: value.utf8)
    }
}
