import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MinecraftKeySetError: Error, Equatable {
    case unavailable
}

public actor MinecraftKeySet {
    public static let url = URL(string: MinecraftTokenTrust.issuer + ".well-known/keys")!

    private let fetch: @Sendable () async throws -> MinecraftTokenTrust
    private let now: @Sendable () -> ContinuousClock.Instant
    private var trust: MinecraftTokenTrust
    private var lastAttempt: ContinuousClock.Instant
    private var lastRefresh: ContinuousClock.Instant
    private var refreshFailed = false
    private var refreshTask: Task<MinecraftTokenTrust, any Error>?

    public init() async throws {
        try await self.init(fetching: Self.fetchKeys)
    }

    init(
        fetching: @escaping @Sendable () async throws -> MinecraftTokenTrust,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) async throws {
        fetch = fetching
        now = clock
        trust = try await fetching()
        lastAttempt = clock()
        lastRefresh = lastAttempt
    }

    public func refresh() async throws {
        if let task = startRefresh() {
            _ = try await task.value
        } else if refreshFailed {
            throw MinecraftKeySetError.unavailable
        }
    }

    public func verify(_ identity: SDPIdentity, fingerprintPayload: Data) async throws {
        try await verify(identity, fingerprintPayload: fingerprintPayload, at: .now)
    }

    func verify(_ identity: SDPIdentity, fingerprintPayload: Data, at date: Date) async throws {
        _ = try await authenticatedKey(for: identity, fingerprintPayload: fingerprintPayload, at: date)
    }

    public func authenticatedKey(for identity: SDPIdentity, fingerprintPayload: Data, at date: Date = .now) async throws -> [UInt8] {
        let age = lastRefresh.duration(to: now())
        if age >= .seconds(21600) {
            guard let task = startRefresh() else { throw MinecraftKeySetError.unavailable }
            let refreshed = try await task.value
            try Task.checkCancellation()
            return try refreshed.authenticatedKey(for: identity, fingerprintPayload: fingerprintPayload, at: date)
        }
        do {
            let key = try trust.authenticatedKey(for: identity, fingerprintPayload: fingerprintPayload, at: date)
            if age >= .seconds(3600) { _ = startRefresh() }
            return key
        } catch NetherNetIdentityError.untrustedKey {
            guard let task = startRefresh() else {
                if refreshFailed { throw MinecraftKeySetError.unavailable }
                throw NetherNetIdentityError.untrustedKey
            }
            let refreshed = try await task.value
            try Task.checkCancellation()
            return try refreshed.authenticatedKey(for: identity, fingerprintPayload: fingerprintPayload, at: date)
        }
    }

    private func startRefresh() -> Task<MinecraftTokenTrust, any Error>? {
        if let refreshTask { return refreshTask }
        let attempt = now()
        guard lastAttempt.duration(to: attempt) >= .seconds(60) else { return nil }
        lastAttempt = attempt
        let task = Task { try await performRefresh() }
        refreshTask = task
        return task
    }

    private func performRefresh() async throws -> MinecraftTokenTrust {
        defer { refreshTask = nil }
        do {
            let result = try await fetch()
            trust = result
            lastRefresh = now()
            refreshFailed = false
            return result
        } catch {
            refreshFailed = true
            throw MinecraftKeySetError.unavailable
        }
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
