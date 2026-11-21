import Foundation

public struct NetherNetPeerIdentity: Equatable, Sendable {
    public let subject: String?
    public let publicKeyDER: [UInt8]

    public init(subject: String? = nil, publicKeyDER: [UInt8]) {
        self.subject = subject
        self.publicKeyDER = publicKeyDER
    }
}

public struct HTTPJoinIdentity: Sendable {
    private let sign: (@Sendable (Data) throws -> SDPIdentity)?
    private let verify: (@Sendable (SDPIdentity, Data) async throws -> NetherNetPeerIdentity?)?

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
        verify = { try await NetherNetPeerIdentity(publicKeyDER: authenticate($0, $1)) }
    }

    public init(
        sign: (@Sendable (Data) throws -> SDPIdentity)? = nil,
        authenticatePeer: @escaping @Sendable (SDPIdentity, Data) async throws -> NetherNetPeerIdentity
    ) {
        self.sign = sign
        verify = { try await authenticatePeer($0, $1) }
    }

    func localDescription(_ sdp: String) throws -> String {
        guard let sign else { return sdp }
        return try sign(SDPIdentity.fingerprintPayload(in: sdp)).adding(to: sdp)
    }

    @discardableResult func validateRemote(_ sdp: String) async throws -> NetherNetPeerIdentity? {
        guard let verify else { return nil }
        return try await verify(SDPIdentity(sdp: sdp), SDPIdentity.fingerprintPayload(in: sdp))
    }
}
