import Foundation

public struct HTTPJoinIdentity: Sendable {
    private let sign: (@Sendable (Data) throws -> SDPIdentity)?
    private let verify: (@Sendable (SDPIdentity, Data) async throws -> Void)?

    public init(
        sign: (@Sendable (Data) throws -> SDPIdentity)? = nil,
        verify: (@Sendable (SDPIdentity, Data) async throws -> Void)? = nil
    ) {
        self.sign = sign
        self.verify = verify
    }

    func localDescription(_ sdp: String) throws -> String {
        guard let sign else { return sdp }
        return try sign(SDPIdentity.fingerprintPayload(in: sdp)).adding(to: sdp)
    }

    func validateRemote(_ sdp: String) async throws {
        guard let verify else { return }
        try await verify(SDPIdentity(sdp: sdp), SDPIdentity.fingerprintPayload(in: sdp))
    }
}
