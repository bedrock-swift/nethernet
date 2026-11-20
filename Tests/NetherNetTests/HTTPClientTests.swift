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
