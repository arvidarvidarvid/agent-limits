import Foundation

/// User config at ~/.config/agent-limits/config.json. Holds the Claude OAuth
/// tokens the app refreshes over time (seeded once from the keychain), plus
/// optional manual overrides. The app both reads and writes this file.
///
///   {
///     "claudeAccessToken":  "sk-ant-oat01-...",
///     "claudeRefreshToken": "sk-ant-ort01-...",
///     "claudeExpiresAt":     1789972755000,      // unix millis
///     "codexToken":          "..."               // rarely needed
///   }
struct AppConfig: Codable {
    var claudeAccessToken: String?
    var claudeRefreshToken: String?
    var claudeExpiresAt: Int?      // unix milliseconds
    var codexToken: String?

    /// Legacy field: a setup-token pasted by hand. Kept for back-compat, but it
    /// lacks the user:profile scope the usage endpoint needs, so it is unused.
    var claudeToken: String?

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/agent-limits/config.json")

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: path),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return cfg
    }

    func save() {
        do {
            try FileManager.default.createDirectory(
                at: Self.path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: Self.path, options: .atomic)
            // Tokens are secrets; keep the file readable only by the owner.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.path.path)
        } catch {
            NSLog("AgentLimits: failed to save config: \(error)")
        }
    }
}
