import Foundation

/// Produces a valid, profile-scoped Claude access token, refreshing it when
/// needed. The usage endpoint requires the user:profile scope, which the
/// subscription OAuth token carries; a refresh preserves that scope.
///
/// Token sources, in order: a fresh token cached in the app config, otherwise a
/// refresh (config refresh token, else one seeded from the keychain), otherwise
/// a still-fresh keychain access token.
enum ClaudeAuth {
    // Claude Code's public OAuth client id and token endpoint.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    // platform.claude.com is behind Cloudflare, which 1010-blocks default HTTP
    // client UAs and 429s browser-like ones. A plain app name passes.
    static let userAgent = "agent-limits/0.1"

    struct AuthError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let freshnessMarginMillis = 60_000

    static func accessToken(session: URLSession) async throws -> String {
        var cfg = AppConfig.load()
        let now = Int(Date().timeIntervalSince1970 * 1000)

        // 1. A cached access token with comfortable headroom.
        if let at = cfg.claudeAccessToken, let exp = cfg.claudeExpiresAt,
           exp > now + freshnessMarginMillis {
            return at
        }

        // 2. Refresh, using the config refresh token or one seeded from disk.
        let seed = Credentials.claudeSeed()
        if let refreshTok = cfg.claudeRefreshToken ?? seed?.refreshToken {
            let renewed = try await performRefresh(refreshTok, session: session)
            cfg.claudeAccessToken = renewed.accessToken
            cfg.claudeRefreshToken = renewed.refreshToken ?? refreshTok
            cfg.claudeExpiresAt = renewed.expiresAtMillis
            cfg.claudeToken = nil // drop any stale hand-pasted token
            cfg.save()
            return renewed.accessToken
        }

        // 3. No refresh token anywhere, but a keychain access token still valid.
        if let seed, seed.expiresAtMillis > now + freshnessMarginMillis {
            return seed.accessToken
        }

        throw AuthError(message: "No Claude credentials. Log in with `claude`.")
    }

    private static func performRefresh(_ refreshToken: String, session: URLSession) async throws -> Credentials.ClaudeBlob {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 403 {
                throw AuthError(message: "Refresh blocked by Cloudflare (403). Try again shortly.")
            }
            let detail = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw AuthError(message: "Token refresh failed (HTTP \(http.statusCode)). \(detail)")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String else {
            throw AuthError(message: "Token refresh returned no access_token.")
        }
        let newRefresh = root["refresh_token"] as? String
        let expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue ?? 0
        let expiresAt = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
        return Credentials.ClaudeBlob(accessToken: access, refreshToken: newRefresh, expiresAtMillis: expiresAt)
    }
}
