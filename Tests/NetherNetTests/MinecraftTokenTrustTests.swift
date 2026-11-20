import Foundation
import NetherNet
import Testing

@Test func minecraftTokenVerifiesIssuerSignatureClaimsAndSDPBinding() throws {
    let jwks = #"{"keys":[{"kty":"RSA","n":"pTUuCaZ1FJutp8a0ksSrjy4dT4_sQi7mXsSzxUKsJ4Shob7ihAzzOihIRbhCDz8h-EWci6Dv8d-lsw9iV7AeBxs6jIgEX7fdyJgfMu9coeGD0z90kY2V9DzssrIuhLuoVC5QJ55e0fOyXtK4ZUIJXC206rHx2kYm1kKOcPnuwDNBJvNCKxyWejfnIIxnXqqPPeytKMmnhtuIDfzA7DIAo9UkpqhtTWI23AHp5y6fOk3QStrVRm5uLTAxSotSOKdfry6E_qxHXLEoWZvdcJy0v4VUkiWcB1waOQVHgQrvEMdgH2kdBFaK7tPjV1sFc_akrnYvTZnGJe6xgSZKUxeI9w","e":"AQAB","kid":"test","alg":"RS256","use":"sig"}]}"#
    let fingerprintSignature = "eyJhbGciOiJFUzM4NCJ9..BaiAxeOJA1V0l51OeIeFShUxD1HsG96sWwsXAHaQGh1MHFMCHaLn1jJdMDXqTC5OTYXPc6KrwLUdE4Ye6u31NM2tDeL7CgPXyR0VaB5nklESsn4aDHAwwd_b5umcvLVM"
    let token = "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3QifQ.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24uZnJhbmNoaXNlLm1pbmVjcmFmdC1zZXJ2aWNlcy5uZXQvIiwiYXVkIjpbImFwaTovL2F1dGgtbWluZWNyYWZ0LXNlcnZpY2VzL211bHRpcGxheWVyIl0sInN1YiI6InRlc3QtcGxheWVyIiwiZXhwIjoyMDAwLCJjcGsiOiJNSFl3RUFZSEtvWkl6ajBDQVFZRks0RUVBQ0lEWWdBRTFldGdLNXM2UERrckloQ2ltWUtwMEd6bElsSlBvM1JVWThyS2JDVUtFR1VlS2hydmlkaWE0ZmFobG1mOEllTHJHcWpIMkw3LzJyVmhiaFhvK2Q3aFhBdENpbWM1eTZGQzVGYUdKSUI3OG1JUFNXaXZud1cyQVZKSVhvYXREbVBmIn0.ZHAqPxyCkEtWKJRpfjbZwODJmA-nq29rLxBGCuZaArCbIQuhbeR_Ui4Mn3lk-r8_hNvko6r4tdMbZr1QH1yqy9ETPduYD4Nom88fbIJftIjAURMaCd466QDWHgDjgJSdhLIqh3us3xwNvmI_GLFNHZGkCAX_pijh6JPmmiCROamybrCh4HKS2Ke49NNO5c50dWcVUJ4tCkXWBx-OA6CC8VGee7H62fYlP5CJZZ0087Yu9Gh-vSot97bZA3Res0NJgrJV49E4fNjN5jXaEkOjNCcZncmVHDxutsDEsO-mypQieAcwZuOa2kDh4lb7bENNgwJl-si1WS43dON3FXk9PA"
    let wrongAudienceToken = "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3QifQ.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24uZnJhbmNoaXNlLm1pbmVjcmFmdC1zZXJ2aWNlcy5uZXQvIiwiYXVkIjoib3RoZXItYXVkaWVuY2UiLCJzdWIiOiJ0ZXN0LXBsYXllciIsImV4cCI6MjAwMCwiY3BrIjoiTUhZd0VBWUhLb1pJemowQ0FRWUZLNEVFQUNJRFlnQUUxZXRnSzVzNlBEa3JJaENpbVlLcDBHemxJbEpQbzNSVVk4cktiQ1VLRUdVZUtocnZpZGlhNGZhaGxtZjhJZUxyR3FqSDJMNy8yclZoYmhYbytkN2hYQXRDaW1jNXk2RkM1RmFHSklCNzhtSVBTV2l2bndXMkFWSklYb2F0RG1QZiJ9.HQ77sh2gPQbSv_xtsuo0TH1LUbnj8LZMhCviOBRpBLk7dvqBs_1HgzcjlP0ZGMxlQEYvgALbHynmu2SbMmsiu4bYXhKYviene6qBcSEVm5_ks3cfBOxotORCSifmVHk5258vOKd97ghYh_SlEbIm-zyjnXzrhS_5sw14FeZj_yauIjIoyVgv4Z4z5YTjdVJlw3fVteJltM8w-1-37PlFbgX51IGR6GY_BHAE3eiXpcglck-i3pwIiVZHGNvJI7JUgWhDtG-JQE1xH43K8-ORp5r1VWsjTKNyHDvlaJRxfeHA2jQDEQHaqJsBSqjAj3Gd8iIlXv0PIA9-gQF5K9jDOg"
    let identity = try SDPIdentity(domain: "minecraft.test", token: token, fingerprintSignature: fingerprintSignature)
    let wrongAudience = try SDPIdentity(domain: "minecraft.test", token: wrongAudienceToken, fingerprintSignature: fingerprintSignature)
    let trust = try MinecraftTokenTrust(jwks: Data(jwks.utf8))
    let payload = Data("fingerprint".utf8)
    let now = Date(timeIntervalSince1970: 1000)

    try trust.verify(identity, fingerprintPayload: payload, at: now)
    let object = try #require(JSONSerialization.jsonObject(with: Data(jwks.utf8)) as? [String: [[String: String]]])
    let key = try #require(object["keys"]?.first)
    var duplicate = key
    duplicate["kid"] = "duplicate"
    let mixed = try JSONSerialization.data(withJSONObject: [
        "keys": [false, ["kty": "RSA"], duplicate, key, duplicate, ["kty": "RSA", "kid": "bad", "n": "!"]]
    ])
    try MinecraftTokenTrust(jwks: mixed).verify(identity, fingerprintPayload: payload, at: now)
    let ambiguous = try JSONSerialization.data(withJSONObject: ["keys": [key, key]])
    #expect(throws: NetherNetIdentityError.untrustedKey) { try MinecraftTokenTrust(jwks: ambiguous) }
    #expect(throws: NetherNetIdentityError.invalidSignature) {
        try trust.verify(identity, fingerprintPayload: Data("different".utf8), at: now)
    }
    #expect(throws: NetherNetIdentityError.expiredToken) {
        try trust.verify(identity, fingerprintPayload: payload, at: Date(timeIntervalSince1970: 2000))
    }
    #expect(throws: NetherNetIdentityError.invalidClaims) {
        try trust.verify(wrongAudience, fingerprintPayload: payload, at: now)
    }
}
