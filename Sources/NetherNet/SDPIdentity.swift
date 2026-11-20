import Foundation

public enum SDPIdentityError: Error, Equatable {
    case missing
    case duplicate
    case malformed
}

public struct SDPIdentity: Equatable, Sendable {
    public let domain: String
    public let token: String
    public let fingerprintSignature: String

    public init(domain: String, token: String, fingerprintSignature: String) throws {
        guard !domain.isEmpty, Self.isCompact(token, detached: false),
              Self.isCompact(fingerprintSignature, detached: true) else { throw SDPIdentityError.malformed }
        self.domain = domain
        self.token = token
        self.fingerprintSignature = fingerprintSignature
    }

    public init(sdp: String) throws {
        let attributes = Self.lines(sdp).filter { $0.hasPrefix(Self.attribute) }
        guard let attribute = attributes.first else { throw SDPIdentityError.missing }
        guard attributes.count == 1 else { throw SDPIdentityError.duplicate }
        let value = String(attribute.dropFirst(Self.attribute.count))
        guard let json = Data(base64Encoded: value) else { throw SDPIdentityError.malformed }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: json), envelope.idp.protocol == "default",
              let assertion = try? decoder.decode(Assertion.self, from: Data(envelope.assertion.utf8)) else {
            throw SDPIdentityError.malformed
        }
        try self.init(domain: envelope.idp.domain, token: assertion.token, fingerprintSignature: assertion.fingerprints)
    }

    public func adding(to sdp: String) throws -> String {
        var lines = Self.lines(sdp)
        guard !lines.contains(where: { $0.hasPrefix(Self.attribute) }) else { throw SDPIdentityError.duplicate }
        let encoder = JSONEncoder()
        let assertion = try encoder.encode(Assertion(token: token, fingerprints: fingerprintSignature))
        let envelope = Envelope(
            idp: Provider(domain: domain, protocol: "default"),
            assertion: String(decoding: assertion, as: UTF8.self)
        )
        let attribute = Self.attribute + (try encoder.encode(envelope)).base64EncodedString()
        let position = lines.firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex
        if position == lines.endIndex, lines.last == "" {
            lines.insert(attribute, at: position - 1)
        } else {
            lines.insert(attribute, at: position)
        }
        return lines.joined(separator: "\r\n")
    }

    public static func fingerprintPayload(in sdp: String) throws -> Data {
        let prefix = "a=fingerprint:"
        let fingerprints = try lines(sdp).filter { $0.hasPrefix(prefix) }.map { line in
            let words = line.dropFirst(prefix.count).split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard words.count == 2 else { throw SDPIdentityError.malformed }
            return Fingerprint(algorithm: String(words[0]), digest: String(words[1]))
        }
        guard !fingerprints.isEmpty else { throw SDPIdentityError.missing }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(FingerprintPayload(fingerprint: fingerprints))
    }

    private static let attribute = "a=identity:"

    private static func lines(_ sdp: String) -> [String] {
        sdp.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func isCompact(_ value: String, detached: Bool) -> Bool {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, !fields[0].isEmpty, !fields[2].isEmpty,
              fields[1].isEmpty == detached else { return false }
        return fields.allSatisfy { field in
            field.utf8.allSatisfy { byte in
                switch byte {
                case 45, 48...57, 65...90, 95, 97...122: true
                default: false
                }
            }
        }
    }

    private struct Provider: Codable {
        let domain: String
        let `protocol`: String
    }

    private struct Assertion: Codable {
        let token: String
        let fingerprints: String
    }

    private struct Envelope: Codable {
        let idp: Provider
        let assertion: String
    }

    private struct Fingerprint: Encodable {
        let algorithm: String
        let digest: String
    }

    private struct FingerprintPayload: Encodable {
        let fingerprint: [Fingerprint]
    }
}
