import Foundation

/// Produces a valid, profile-scoped Claude access token, refreshing it when
/// needed. The usage endpoint requires the user:profile scope, which the
/// subscription OAuth token carries; a refresh preserves that scope.
///
/// Token sources, in order: a fresh token cached in the app config, a refresh
/// with the config refresh token, a still-fresh keychain access token, then a
/// refresh with the keychain refresh token. A refresh token the server rejects
/// as invalid_grant is dropped and the next source is tried.
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

        // 2. Refresh with the config refresh token. If it has expired or been
        //    revoked, forget it so it can't keep failing, and fall back to disk.
        let seed = Credentials.claudeSeed()
        var spent: String?
        if let refreshTok = cfg.claudeRefreshToken {
            do {
                return try await refreshAndStore(refreshTok, into: &cfg, session: session)
            } catch is InvalidGrant {
                spent = refreshTok
                cfg.claudeAccessToken = nil
                cfg.claudeRefreshToken = nil
                cfg.claudeExpiresAt = nil
                cfg.save()
            }
        }

        // 3. A still-fresh keychain access token needs no refresh at all.
        if let seed, seed.expiresAtMillis > now + freshnessMarginMillis {
            return seed.accessToken
        }

        // 4. Refresh with the keychain refresh token (e.g. after a fresh `claude` login).
        if let refreshTok = seed?.refreshToken, refreshTok != spent {
            do {
                return try await refreshAndStore(refreshTok, into: &cfg, session: session)
            } catch is InvalidGrant {
                spent = refreshTok
            }
        }

        if spent != nil {
            throw AuthError(message: "Claude login expired. Run `claude` and /login again.")
        }
        throw AuthError(message: "No Claude credentials. Log in with `claude`.")
    }

    /// The token endpoint rejected the refresh token itself (expired or revoked).
    private struct InvalidGrant: Error {}

    private static func refreshAndStore(_ refreshTok: String, into cfg: inout AppConfig,
                                        session: URLSession) async throws -> String {
        let renewed = try await performRefresh(refreshTok, session: session)
        cfg.claudeAccessToken = renewed.accessToken
        cfg.claudeRefreshToken = renewed.refreshToken ?? refreshTok
        cfg.claudeExpiresAt = renewed.expiresAtMillis
        cfg.claudeToken = nil // drop any stale hand-pasted token
        cfg.save()
        return renewed.accessToken
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
            if http.statusCode == 400, String(data: data, encoding: .utf8)?.contains("invalid_grant") == true {
                throw InvalidGrant()
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
