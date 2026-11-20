import Foundation
import NetherNet
import Testing

@Test func detachedES384JWSRecreatesTheSigningInput() throws {
    let detached = "eyJhbGciOiJFUzM4NCJ9..kNia0py7TORe8vbpAEC7P_ECi64lJoGrBIzxcGSfBZX1Ch79kbRbjHkv8qsqENlTNPzWOyiNtt7FhCq1Kv02xpOOx9lXWLDFwFNuLIclNqI-J--v1eIjcBByKNWB8Z6m"
    let payload = Data(#"{"fingerprint":[]}"#.utf8)
    let jws = try ES384JWS(compact: detached, detachedPayload: payload)
    #expect(jws.payload == payload)
    #expect(String(decoding: jws.signingInput, as: UTF8.self) == "eyJhbGciOiJFUzM4NCJ9.eyJmaW5nZXJwcmludCI6W119")
    #expect(jws.signature.count == 96)
    let signed = try ES384JWS.sign(payload, detached: true) { input in
        #expect(input == jws.signingInput)
        return jws.signature
    }
    #expect(signed == detached)
}

@Test func es384JWSRejectsTheWrongProtectedAlgorithm() throws {
    let signature = String(repeating: "A", count: 128)
    let compact = "eyJhbGciOiJub25lIn0.e30." + signature
    #expect(throws: ES384JWS.FormatError.unsupportedHeader) { try ES384JWS(compact: compact) }
}
