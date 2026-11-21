import Crypto
import Foundation

public enum NetherNetIdentityError: Error, Equatable {
    case invalidClaims
    case expiredToken
    case untrustedKey
    case invalidSignature
}

public struct NetherNetSigningKey: Sendable {
    static let clockSkew: TimeInterval = 60

    private let key: P384.Signing.PrivateKey
    public let domain: String

    public init(domain: String = "self") {
        key = P384.Signing.PrivateKey()
        self.domain = domain.isEmpty ? "self" : domain
    }

    public init(pemRepresentation: String, domain: String = "self") throws {
        key = try P384.Signing.PrivateKey(pemRepresentation: pemRepresentation)
        self.domain = domain.isEmpty ? "self" : domain
    }

    public var pemRepresentation: String { key.pemRepresentation }
    public var publicKeyDER: Data { key.publicKey.derRepresentation }

    public func assertion(for fingerprintPayload: Data, at now: Date = .now) throws -> SDPIdentity {
        guard let issued = Int64(exactly: now.timeIntervalSince1970.rounded(.down)),
              (0...(Int64.max - 60)).contains(issued) else { throw NetherNetIdentityError.invalidClaims }
        let claims = IssuedClaims(cpk: publicKeyDER.base64EncodedString(), iss: domain, iat: issued, exp: issued + 60)
        let token = try ES384JWS.sign(JSONEncoder().encode(claims)) { try key.signature(for: $0).rawRepresentation }
        let signature = try ES384JWS.sign(fingerprintPayload, detached: true) { try key.signature(for: $0).rawRepresentation }
        return try SDPIdentity(domain: domain, token: token, fingerprintSignature: signature)
    }

    public static func verifier(pinning publicKeyDER: Data) throws -> @Sendable (SDPIdentity, Data) throws -> Void {
        let key = try P384.Signing.PublicKey(derRepresentation: publicKeyDER)
        return { identity, payload in try validate(identity, payload: payload, key: key, at: .now) }
    }

    static func validate(
        _ identity: SDPIdentity, payload: Data, key: P384.Signing.PublicKey, at now: Date
    ) throws {
        let token = try ES384JWS(compact: identity.token)
        guard verify(token, with: key) else { throw NetherNetIdentityError.invalidSignature }
        let claims = try JSONDecoder().decode(ReceivedClaims.self, from: token.payload)
        let time = now.timeIntervalSince1970
        guard claims.exp > time - Self.clockSkew else { throw NetherNetIdentityError.expiredToken }
        guard (claims.nbf ?? time) <= time + Self.clockSkew else { throw NetherNetIdentityError.invalidClaims }
        guard claims.cpk.key.x963Representation == key.x963Representation else { throw NetherNetIdentityError.untrustedKey }
        guard claims.iss == nil || claims.iss == identity.domain else { throw NetherNetIdentityError.invalidClaims }
        try verifyFingerprint(identity, payload: payload, key: key)
    }

    static func verifyFingerprint(_ identity: SDPIdentity, payload: Data, key: P384.Signing.PublicKey) throws {
        let signature = try ES384JWS(compact: identity.fingerprintSignature, detachedPayload: payload)
        guard verify(signature, with: key) else { throw NetherNetIdentityError.invalidSignature }
    }

    private static func verify(_ jws: ES384JWS, with key: P384.Signing.PublicKey) -> Bool {
        guard let signature = try? P384.Signing.ECDSASignature(rawRepresentation: jws.signature) else { return false }
        return key.isValidSignature(signature, for: jws.signingInput)
    }

    private struct IssuedClaims: Encodable {
        let cpk: String
        let iss: String
        let iat: Int64
        let exp: Int64
    }

    private struct ReceivedClaims: Decodable {
        let cpk: IdentityPublicKey
        let iss: String?
        let exp: Double
        let nbf: Double?
    }
}

struct IdentityPublicKey: Decodable {
    let key: P384.Signing.PublicKey

    init(from decoder: any Decoder) throws {
        if let encoded = try? decoder.singleValueContainer().decode(String.self) {
            guard let data = Data(base64Encoded: encoded) else { throw NetherNetIdentityError.invalidClaims }
            key = try P384.Signing.PublicKey(derRepresentation: data)
        } else {
            let jwk = try JWK(from: decoder)
            guard jwk.kty == "EC", jwk.crv == "P-384",
                  let x = ES384JWS.decode(jwk.x), let y = ES384JWS.decode(jwk.y),
                  x.count == 48, y.count == 48 else { throw NetherNetIdentityError.invalidClaims }
            key = try P384.Signing.PublicKey(x963Representation: Data([4]) + x + y)
        }
    }

    private struct JWK: Decodable {
        let kty: String
        let crv: String
        let x: String
        let y: String
    }
}
