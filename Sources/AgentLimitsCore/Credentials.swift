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
    ///
    /// Two steps, because macOS rejects kSecReturnData combined with
    /// kSecMatchLimitAll for password items (errSecParam): list the matching
    /// accounts first (attributes only, which never prompts), then fetch each
    /// item's secret on its own.
    private static func keychainData(service: String) -> [Data] {
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var listResult: CFTypeRef?
        guard SecItemCopyMatching(listQuery as CFDictionary, &listResult) == errSecSuccess,
              let items = listResult as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            securityCLIPassword(service: service, account: item[kSecAttrAccount as String] as? String)
        }
    }

    /// Read an item's secret through /usr/bin/security rather than
    /// SecItemCopyMatching. The keychain grants access per app, and an ad-hoc
    /// signed binary's identity is its code hash, which changes on every
    /// rebuild, so reading the item directly raised a fresh "wants to use your
    /// confidential information" prompt after each build ("Always Allow" only
    /// covered the old binary). Claude Code writes this item with
    /// /usr/bin/security, so that Apple-signed tool is already on the item's
    /// access list and reads it without prompting.
    private static func securityCLIPassword(service: String, account: String?) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        proc.arguments = args + ["-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        // -w prints the secret followed by a newline.
        return data.last == UInt8(ascii: "\n") ? data.dropLast() : data
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
