import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor MinecraftKeySet {
    public static let url = URL(string: MinecraftTokenTrust.issuer + ".well-known/keys")!

    private let fetch: @Sendable () async throws -> MinecraftTokenTrust
    private var trust: MinecraftTokenTrust
    private var lastAttempt = ContinuousClock.now
    private var lastRefresh = ContinuousClock.now
    private var refreshTask: Task<MinecraftTokenTrust, any Error>?

    public init() async throws {
        try await self.init(fetching: Self.fetchKeys)
    }

    init(fetching: @escaping @Sendable () async throws -> MinecraftTokenTrust) async throws {
        fetch = fetching
        trust = try await fetching()
        lastAttempt = .now
        lastRefresh = lastAttempt
    }

    public func refresh() async throws {
        if canRefresh { _ = try await update() }
    }

    public func verify(_ identity: SDPIdentity, fingerprintPayload: Data) async throws {
        if lastRefresh.duration(to: .now) >= .seconds(3600) {
            guard canRefresh else { throw NetherNetIdentityError.untrustedKey }
            let refreshed = try await update()
            try Task.checkCancellation()
            try refreshed.verify(identity, fingerprintPayload: fingerprintPayload)
            return
        }
        do {
            try trust.verify(identity, fingerprintPayload: fingerprintPayload)
        } catch NetherNetIdentityError.untrustedKey {
            guard canRefresh else { throw NetherNetIdentityError.untrustedKey }
            let refreshed = try await update()
            try Task.checkCancellation()
            try refreshed.verify(identity, fingerprintPayload: fingerprintPayload)
        }
    }

    private var canRefresh: Bool {
        refreshTask != nil || lastAttempt.duration(to: .now) >= .seconds(60)
    }

    private func update() async throws -> MinecraftTokenTrust {
        if let refreshTask { return try await refreshTask.value }
        let fetch = self.fetch
        let task = Task { try await fetch() }
        refreshTask = task
        lastAttempt = .now
        defer { refreshTask = nil }
        let result = try await task.value
        trust = result
        lastRefresh = .now
        return result
    }

    private static func fetchKeys() async throws -> MinecraftTokenTrust {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (status, data) = try await HTTPBody.load(request)
        guard (200..<300).contains(status) else { throw HTTPJoinError.status(status) }
        return try MinecraftTokenTrust(jwks: data)
    }
}
