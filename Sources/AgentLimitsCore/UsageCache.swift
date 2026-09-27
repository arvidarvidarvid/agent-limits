import Foundation

/// The last good usage response for one provider, plus any rate-limit backoff,
/// kept on disk so the app and every CLI invocation share it. The usage
/// endpoints rate-limit aggressively, and each CLI call is a new process, so an
/// in-memory cache or backoff would not survive between calls.
struct UsageCache: Codable {
    /// The raw response body, re-decoded on read so decoder fixes apply to it too.
    var body: Data?
    var fetchedAt: Date?
    /// Don't call the endpoint again before this (set after an HTTP 429).
    var retryAfter: Date?
    /// The last backoff applied, doubled on each consecutive 429.
    var backoffSeconds: Double?

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/agent-limits")

    static func url(_ provider: String) -> URL {
        directory.appendingPathComponent("\(provider.lowercased()).json")
    }

    /// Held while checking the cache and fetching, so concurrent callers wait
    /// for one request and then reuse its result instead of each firing one.
    static func lock(_ provider: String) -> FileLock {
        FileLock(directory.appendingPathComponent("\(provider.lowercased()).lock"))
    }

    static func load(_ provider: String) -> UsageCache {
        guard let data = try? Data(contentsOf: url(provider)),
              let cache = try? JSONDecoder().decode(UsageCache.self, from: data) else {
            return UsageCache()
        }
        return cache
    }

    func save(_ provider: String) {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.url(provider), options: .atomic)
        } catch {
            NSLog("AgentLimits: failed to save usage cache: \(error)")
        }
    }
}
