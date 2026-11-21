import Crypto
import Foundation
import Testing
@testable import NetherNet

@Test func pinnedAssertionsAllowBoundedClockSkew() throws {
    let key = P384.Signing.PrivateKey()
    let payload = Data("fingerprint".utf8)
    let claims = try JSONSerialization.data(withJSONObject: [
        "cpk": key.publicKey.derRepresentation.base64EncodedString(), "nbf": 1000, "exp": 1100
    ])
    let token = try ES384JWS.sign(claims) { try key.signature(for: $0).rawRepresentation }
    let signature = try ES384JWS.sign(payload, detached: true) { try key.signature(for: $0).rawRepresentation }
    let identity = try SDPIdentity(domain: "example.test", token: token, fingerprintSignature: signature)
    for allowed in [940.0, 1159.0] {
        try NetherNetSigningKey.validate(identity, payload: payload, key: key.publicKey, at: Date(timeIntervalSince1970: allowed))
    }
    #expect(throws: NetherNetIdentityError.invalidClaims) {
        try NetherNetSigningKey.validate(identity, payload: payload, key: key.publicKey, at: Date(timeIntervalSince1970: 939))
    }
    #expect(throws: NetherNetIdentityError.expiredToken) {
        try NetherNetSigningKey.validate(identity, payload: payload, key: key.publicKey, at: Date(timeIntervalSince1970: 1160))
    }
}

@Test func pinnedIdentityVerifiesTheKeyAndFingerprint() throws {
    let key = NetherNetSigningKey(domain: "example.test")
    let restored = try NetherNetSigningKey(pemRepresentation: key.pemRepresentation, domain: key.domain)
    let payload = Data("fingerprint".utf8)
    let assertion = try restored.assertion(for: payload)
    #expect(key.publicKeyDER == restored.publicKeyDER)

    let verify = try NetherNetSigningKey.verifier(pinning: key.publicKeyDER)
    try verify(assertion, payload)
    #expect(throws: NetherNetIdentityError.invalidSignature) { try verify(assertion, Data("changed".utf8)) }

    let expired = try restored.assertion(for: payload, at: Date(timeIntervalSince1970: 10))
    #expect(throws: NetherNetIdentityError.expiredToken) { try verify(expired, payload) }

    let another = try NetherNetSigningKey.verifier(pinning: NetherNetSigningKey().publicKeyDER)
    #expect(throws: NetherNetIdentityError.invalidSignature) { try another(assertion, payload) }
}
