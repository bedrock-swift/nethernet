import Foundation
import NetherNet
import Testing

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
