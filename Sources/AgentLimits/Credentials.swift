import Foundation
import Security

/// Reads the OAuth credentials that the Claude Code and Codex CLIs already store
/// on this machine. Nothing is written; we only read what the CLIs put there.
enum Credentials {

    struct MissingCredential: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    // MARK: Claude

    /// A Claude OAuth blob: an access token, the refresh token that renews it,
    /// and when the access token expires (unix millis, 0 if unknown).
    struct ClaudeBlob {
        var accessToken: String
        var refreshToken: String?
        var expiresAtMillis: Int
    }

    /// Claude Code stores its OAuth blob either in the login keychain (service
    /// "Claude Code-credentials" or "Claude Code") or in ~/.claude/.credentials.json.
    /// Any of them can be stale, so read all and return the freshest by expiry.
    /// (Learned from PanithanNanti/claude-usage-widget, where a stale file
    /// shadowing a fresh keychain caused every refresh to fail.)
    static func claudeSeed() -> ClaudeBlob? {
        var best: ClaudeBlob?
        func consider(_ data: Data?) {
            guard let data, let blob = parseClaudeBlob(data) else { return }
            if best == nil || blob.expiresAtMillis > best!.expiresAtMillis {
                best = blob
            }
        }

        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        consider(try? Data(contentsOf: file))

        for service in ["Claude Code-credentials", "Claude Code"] {
            for data in keychainData(service: service) { consider(data) }
        }
        return best
    }

    /// All generic-password items for a service. There can be more than one
    /// (e.g. keyed by email vs unix username); return them all so the caller
    /// can pick the freshest instead of whichever the keychain hands back first.
    private static func keychainData(service: String) -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        if let many = result as? [Data] { return many }
        if let one = result as? Data { return [one] }
        return []
    }

    private static func parseClaudeBlob(_ data: Data) -> ClaudeBlob? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // The blob may be wrapped in {"claudeAiOauth": {...}} or bare.
        let o = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let access = o["accessToken"] as? String, !access.isEmpty else { return nil }
        let refresh = o["refreshToken"] as? String
        let expires = (o["expiresAt"] as? NSNumber)?.intValue ?? 0
        return ClaudeBlob(accessToken: access, refreshToken: refresh, expiresAtMillis: expires)
    }

    // MARK: Codex

    /// Codex stores its ChatGPT OAuth tokens in a plain file at ~/.codex/auth.json.
    struct CodexToken {
        let accessToken: String
        let accountId: String?
    }

    static func codex() throws -> CodexToken {
        if let token = AppConfig.load().codexToken, !token.isEmpty {
            return CodexToken(accessToken: token, accountId: nil)
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path) else {
            throw MissingCredential(what: "Codex auth.json not found (log in with `codex`).")
        }
        struct Blob: Decodable {
            struct Tokens: Decodable {
                let access_token: String
                let account_id: String?
            }
            let tokens: Tokens
        }
        let blob = try JSONDecoder().decode(Blob.self, from: data)
        return CodexToken(accessToken: blob.tokens.access_token, accountId: blob.tokens.account_id)
    }
}
