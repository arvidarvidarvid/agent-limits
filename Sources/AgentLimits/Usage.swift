import Foundation

/// One rate-limit window as the menu renders it: a human label, how much of the
/// window is used (0...100), when it resets, and what role it plays (so the
/// menu-bar title can pick, say, the weekly window specifically).
struct RateWindow: Identifiable {
    enum Kind { case session, weekly, weeklyScoped, spend, other }

    let id = UUID()
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    var kind: Kind = .other
}

/// Everything the menu shows for a single subscription.
struct ProviderUsage {
    let provider: String
    var windows: [RateWindow]
    var error: String?

    static func failed(_ provider: String, _ message: String) -> ProviderUsage {
        ProviderUsage(provider: provider, windows: [], error: message)
    }
}

enum Usage {
    private static let session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return c
    }())

    static func fetchAll() async -> [ProviderUsage] {
        async let claude = fetchClaude()
        async let codex = fetchCodex()
        return await [claude, codex]
    }

    // MARK: Claude

    static func fetchClaude() async -> ProviderUsage {
        do {
            let token = try await ClaudeAuth.accessToken(session: session)
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue(ClaudeAuth.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await session.data(for: req)
            try check(resp, data)
            return try ClaudeDecoder.decode(data)
        } catch {
            return .failed("Claude", message(from: error))
        }
    }

    // MARK: Codex

    static func fetchCodex() async -> ProviderUsage {
        do {
            let token = try Credentials.codex()
            var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue(ClaudeAuth.userAgent, forHTTPHeaderField: "User-Agent")
            if let acc = token.accountId {
                req.setValue(acc, forHTTPHeaderField: "chatgpt-account-id")
            }
            let (data, resp) = try await session.data(for: req)
            try check(resp, data)
            return try CodexDecoder.decode(data)
        } catch {
            return .failed("Codex", message(from: error))
        }
    }

    // MARK: Helpers

    struct HTTPError: LocalizedError {
        let code: Int
        let body: String
        var errorDescription: String? {
            code == 401 ? "Not authorized (token expired?)" : "HTTP \(code)"
        }
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw HTTPError(code: http.statusCode, body: body)
        }
    }

    private static func message(from error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
