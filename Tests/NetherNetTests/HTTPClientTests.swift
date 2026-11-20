import Foundation
@testable import NetherNet
import Testing

@Test func httpJoinUsesTheLocalNetworkIDInThePath() throws {
    let endpoint = try #require(URL(string: "https://127.0.0.1:19132/"))
    let request = try NetherNetHTTPClient.joinURL(endpoint, networkID: .max)
    #expect(request.absoluteString == "https://127.0.0.1:19132/v1/join/18446744073709551615")

    let invalid = try #require(URL(string: "https://127.0.0.1:19132/other"))
    #expect(throws: HTTPJoinError.invalidEndpoint) { try NetherNetHTTPClient.joinURL(invalid, networkID: 1) }
}

@Test func httpStatusMatchesTheBedrockJSONFields() throws {
    let body = #"{"name":"Server","protocol":0,"version":"","level":"World","players":1,"maxPlayers":8,"gameType":0}"#
    let status = try JSONDecoder().decode(HTTPServerStatus.self, from: Data(body.utf8))
    #expect(status == HTTPServerStatus(
        name: "Server", world: "World", protocolVersion: 0, version: "",
        players: 1, capacity: 8, gameMode: 0
    ))
}

@Test func httpProbeIncludesClientInfoAndUsesTheJoinNetworkID() throws {
    let base = try #require(URL(string: "https://example.test:19132"))
    let client = NetherNetHTTPClient(networkID: 42) { throw ConnectionError.closed }
    let info = HTTPClientInfo(version: "1.21.94", protocolVersion: 819, platform: 7)
    let request = try client.probeRequest(at: base, clientInfo: info)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://example.test:19132/v1/join?version=1.21.94&protocol=819&platform=7&id=42")
    #expect(try client.probeRequest(at: base).url?.query == nil)

    let invalid = HTTPClientInfo(version: "", protocolVersion: 819, platform: 7)
    #expect(throws: HTTPJoinError.invalidClientInfo) { try client.probeRequest(at: base, clientInfo: invalid) }
}
