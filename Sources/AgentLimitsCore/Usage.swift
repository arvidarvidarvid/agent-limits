import Foundation

/// One rate-limit window as the menu renders it: a human label, how much of the
/// window is used (0...100), when it resets, and what role it plays (so the
/// menu-bar title can pick, say, the weekly window specifically).
public struct RateWindow: Identifiable, Sendable {
    public enum Kind: String, Sendable { case session, weekly, weeklyScoped, spend, other }

    public let id = UUID()
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public var kind: Kind = .other
}

/// Everything the menu shows for a single subscription.
public struct ProviderUsage: Sendable {
    public let provider: String
    public var windows: [RateWindow]
    public var error: String?
    /// When this data was fetched from the provider (may be earlier than now
    /// if it came from the shared cache).
    public var fetchedAt: Date? = nil
    /// Set when showing cached data because a fresh fetch wasn't possible.
    public var note: String? = nil

    static func failed(_ provider: String, _ message: String) -> ProviderUsage {
        ProviderUsage(provider: provider, windows: [], error: message)
    }
}

public enum Usage {
    private static let session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return c
    }())

    /// A cached response younger than this is reused without a request.
    public static let minInterval: TimeInterval = 60

    /// Fetch every provider. `force` skips the freshness cache (e.g. an explicit
    /// "Refresh now"), but never an active rate-limit backoff.
    public static func fetchAll(force: Bool = false) async -> [ProviderUsage] {
        async let claude = fetchClaude(force: force)
        async let codex = fetchCodex(force: force)
        return await [claude, codex]
    }

    // MARK: Claude

    public static func fetchClaude(force: Bool = false) async -> ProviderUsage {
        await cachedFetch("Claude", force: force, decode: ClaudeDecoder.decode) {
            let token = try await ClaudeAuth.accessToken(session: session)
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue(ClaudeAuth.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await session.data(for: req)
            try check(resp, data)
            return data
        }
    }

    // MARK: Codex

    public static func fetchCodex(force: Bool = false) async -> ProviderUsage {
        await cachedFetch("Codex", force: force, decode: CodexDecoder.decode) {
            let token = try Credentials.codex()
            var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue(ClaudeAuth.userAgent, forHTTPHeaderField: "User-Agent")
            if let acc = token.accountId {
                req.setValue(acc, forHTTPHeaderField: "chatgpt-account-id")
            }
            let (data, resp) = try await session.data(for: req)
            try check(resp, data)
            return data
        }
    }

    // MARK: Cache and rate limiting

    /// Serve from the shared on-disk cache when it is fresh or when the provider
    /// has told us to back off; otherwise fetch, and remember the result. On a
    /// 429, record a backoff and fall back to the last good data.
    private static func cachedFetch(
        _ provider: String, force: Bool,
        decode: (Data) throws -> ProviderUsage,
        request: () async throws -> Data
    ) async -> ProviderUsage {
        let lock = UsageCache.lock(provider)
        defer { lock.unlock() }
        var cache = UsageCache.load(provider)
        let now = Date()

        func cached(note: String?) -> ProviderUsage? {
            guard let body = cache.body, var usage = try? decode(body) else { return nil }
            usage.fetchedAt = cache.fetchedAt
            usage.note = note
            return usage
        }
        func rateLimitNote(until: Date) -> String {
            var note = "Rate limited, retrying \(Format.relative(until, relativeTo: now))"
            if let at = cache.fetchedAt { note += " · data from \(Format.time(at))" }
            return note
        }

        if let until = cache.retryAfter, until > now {
            return cached(note: rateLimitNote(until: until))
                ?? .failed(provider, rateLimitNote(until: until))
        }
        if !force, let at = cache.fetchedAt, now.timeIntervalSince(at) < minInterval,
           let usage = cached(note: nil) {
            return usage
        }

        do {
            let data = try await request()
            var usage = try decode(data)
            cache.body = data
            cache.fetchedAt = now
            cache.retryAfter = nil
            cache.backoffSeconds = nil
            cache.save(provider)
            usage.fetchedAt = now
            return usage
        } catch let error as HTTPError where error.code == 429 {
            // Honor Retry-After when given; otherwise back off exponentially.
            let backoff = error.retryAfter
                ?? min(max((cache.backoffSeconds ?? 30) * 2, 60), 1800)
            let until = now.addingTimeInterval(backoff)
            cache.backoffSeconds = backoff
            cache.retryAfter = until
            cache.save(provider)
            return cached(note: rateLimitNote(until: until))
                ?? .failed(provider, rateLimitNote(until: until))
        } catch {
            return .failed(provider, message(from: error))
        }
    }

    // MARK: Helpers

    struct HTTPError: LocalizedError {
        let code: Int
        let body: String
        /// Seconds from a Retry-After header, if the server sent one.
        var retryAfter: TimeInterval? = nil
        var errorDescription: String? {
            code == 401 ? "Not authorized (token expired?)" : "HTTP \(code)"
        }
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw HTTPError(code: http.statusCode, body: body, retryAfter: retryAfter)
        }
    }

    private static func message(from error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
