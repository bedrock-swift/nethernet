import Foundation

public struct HTTPJoinIdentity: Sendable {
    private let sign: (@Sendable (Data) throws -> SDPIdentity)?
    private let verify: (@Sendable (SDPIdentity, Data) async throws -> [UInt8]?)?

    public init(
        sign: (@Sendable (Data) throws -> SDPIdentity)? = nil,
        verify: (@Sendable (SDPIdentity, Data) async throws -> Void)? = nil
    ) {
        self.sign = sign
        if let verify {
            self.verify = { identity, payload in
                try await verify(identity, payload)
                return nil
            }
        } else {
            self.verify = nil
        }
    }

    public init(
        sign: (@Sendable (Data) throws -> SDPIdentity)? = nil,
        authenticate: @escaping @Sendable (SDPIdentity, Data) async throws -> [UInt8]
    ) {
        self.sign = sign
        verify = { try await authenticate($0, $1) }
    }

    func localDescription(_ sdp: String) throws -> String {
        guard let sign else { return sdp }
        return try sign(SDPIdentity.fingerprintPayload(in: sdp)).adding(to: sdp)
    }

    @discardableResult func validateRemote(_ sdp: String) async throws -> [UInt8]? {
        guard let verify else { return nil }
        return try await verify(SDPIdentity(sdp: sdp), SDPIdentity.fingerprintPayload(in: sdp))
    }
}
