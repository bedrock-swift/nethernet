import Foundation

public struct ES384JWS: Equatable, Sendable {
    public enum FormatError: Error, Equatable {
        case malformed
        case unsupportedHeader
        case invalidSignatureLength
    }

    public let payload: Data
    public let signingInput: Data
    public let signature: Data

    public init(compact: String, detachedPayload: Data? = nil) throws {
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty,
              let protectedHeader = Self.decode(String(parts[0])),
              let signature = Self.decode(String(parts[2])),
              let header = try? JSONDecoder().decode(Header.self, from: protectedHeader) else {
            throw FormatError.malformed
        }
        guard header.alg == "ES384", header.b64 != false, header.crit?.isEmpty != false else {
            throw FormatError.unsupportedHeader
        }
        guard signature.count == 96 else { throw FormatError.invalidSignatureLength }
        let encodedPayload: String
        if let detachedPayload {
            guard parts[1].isEmpty else { throw FormatError.malformed }
            payload = detachedPayload
            encodedPayload = Self.encode(detachedPayload)
        } else {
            encodedPayload = String(parts[1])
            guard let decoded = Self.decode(encodedPayload) else { throw FormatError.malformed }
            payload = decoded
        }
        signingInput = Data((String(parts[0]) + "." + encodedPayload).utf8)
        self.signature = signature
    }

    public static func sign(_ payload: Data, detached: Bool = false, using sign: (Data) throws -> Data) throws -> String {
        let header = encode(Data(#"{"alg":"ES384"}"#.utf8))
        let encodedPayload = encode(payload)
        let signature = try sign(Data((header + "." + encodedPayload).utf8))
        guard signature.count == 96 else { throw FormatError.invalidSignatureLength } // raw r followed by s
        return header + "." + (detached ? "" : encodedPayload) + "." + encode(signature)
    }

    private struct Header: Decodable {
        let alg: String
        let b64: Bool?
        let crit: [String]?
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ data: String) -> Data? {
        var base64 = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let decoded = Data(base64Encoded: base64), encode(decoded) == data else { return nil }
        return decoded
    }
}
