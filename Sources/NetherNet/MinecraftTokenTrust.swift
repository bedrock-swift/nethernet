import CryptoExtras
import Foundation

public struct MinecraftTokenTrust: Sendable {
    public static let issuer = "https://authorization.franchise.minecraft-services.net/"
    public static let audience = "api://auth-minecraft-services/multiplayer"

    private let keys: [String: _RSA.Signing.PublicKey]

    public init(jwks: Data) throws {
        let set = try JSONDecoder().decode(KeySet.self, from: jwks)
        var keys: [String: _RSA.Signing.PublicKey] = [:]
        for key in set.keys where key.kty == "RSA" && (key.alg == nil || key.alg == "RS256") {
            guard key.use == nil || key.use == "sig" else { continue }
            guard let id = key.kid, !id.isEmpty, keys[id] == nil,
                  let modulus = key.n.flatMap(ES384JWS.decode), let exponent = key.e.flatMap(ES384JWS.decode) else {
                throw NetherNetIdentityError.invalidClaims
            }
            let publicKey = try _RSA.Signing.PublicKey(n: modulus, e: exponent)
            guard publicKey.keySizeInBits >= 2048 else { throw NetherNetIdentityError.untrustedKey }
            keys[id] = publicKey
        }
        guard !keys.isEmpty else { throw NetherNetIdentityError.untrustedKey }
        self.keys = keys
    }

    public func verify(_ identity: SDPIdentity, fingerprintPayload: Data, at now: Date = .now) throws {
        let jws = try CompactJWS(compact: identity.token)
        guard jws.header.alg == "RS256" else { throw ES384JWS.FormatError.unsupportedHeader }
        let signature = _RSA.Signing.RSASignature(rawRepresentation: jws.signature)
        if let id = jws.header.kid {
            guard let key = keys[id] else { throw NetherNetIdentityError.untrustedKey }
            guard key.isValidSignature(signature, for: jws.signingInput, padding: .insecurePKCS1v1_5) else {
                throw NetherNetIdentityError.invalidSignature
            }
        } else {
            guard keys.values.contains(where: { $0.isValidSignature(signature, for: jws.signingInput, padding: .insecurePKCS1v1_5) }) else {
                throw NetherNetIdentityError.invalidSignature
            }
        }
        let claims = try JSONDecoder().decode(Claims.self, from: jws.payload)
        let time = now.timeIntervalSince1970
        guard claims.exp > time else { throw NetherNetIdentityError.expiredToken }
        guard claims.iss == Self.issuer, claims.aud.contains(Self.audience), !claims.sub.isEmpty,
              (claims.nbf ?? time) <= time else { throw NetherNetIdentityError.invalidClaims }
        try NetherNetSigningKey.verifyFingerprint(identity, payload: fingerprintPayload, key: claims.cpk.key)
    }

    private struct KeySet: Decodable {
        let keys: [Key]
    }

    private struct Key: Decodable {
        let kty: String
        let kid: String?
        let alg: String?
        let use: String?
        let n: String?
        let e: String?
    }

    private struct Claims: Decodable {
        let cpk: IdentityPublicKey
        let sub: String
        let iss: String
        let aud: [String]
        let exp: Double
        let nbf: Double?

        private enum CodingKeys: CodingKey { case cpk, sub, iss, aud, exp, nbf }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            cpk = try values.decode(IdentityPublicKey.self, forKey: .cpk)
            sub = try values.decode(String.self, forKey: .sub)
            iss = try values.decode(String.self, forKey: .iss)
            if let audience = try? values.decode(String.self, forKey: .aud) {
                aud = [audience]
            } else {
                aud = try values.decode([String].self, forKey: .aud)
            }
            exp = try values.decode(Double.self, forKey: .exp)
            nbf = try values.decodeIfPresent(Double.self, forKey: .nbf)
        }
    }
}
