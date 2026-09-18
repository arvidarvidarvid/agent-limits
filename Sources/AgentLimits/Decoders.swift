import Foundation

// Both providers report usage with different JSON shapes that drift over time,
// and the real payloads are riddled with nulls. So we walk the JSON loosely with
// JSONSerialization and pull out (label, used%, reset) triples, tolerating a
// missing field anywhere rather than failing the whole decode. The shapes below
// are confirmed against live responses (Codex 2026-09) and the sample published
// by PanithanNanti/claude-usage-widget (Claude 2026-09).

// MARK: Claude

enum ClaudeDecoder {
    // GET /api/oauth/usage. Two representations coexist:
    //   Modern: `limits`: [ { kind, percent, resets_at, scope:{model:{display_name}} } ]
    //           kinds seen: session, weekly_all, weekly_scoped (per-model).
    //   Legacy: `five_hour` / `seven_day` objects with `utilization` + `resets_at`.
    //   Plus `spend`: { percent, enabled } for pay-as-you-go credits.
    // Prefer `limits[]`; fall back to the legacy objects when it is absent.
    static func decode(_ data: Data) throws -> ProviderUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Usage.HTTPError(code: 0, body: "unexpected Claude payload")
        }
        var windows = fromLimitsArray(root)
        if windows.isEmpty { windows = fromLegacyObjects(root) }

        if let spend = root["spend"] as? [String: Any],
           (spend["enabled"] as? Bool) == true,
           let pct = JSON.percent(spend["percent"]) {
            windows.append(RateWindow(label: "Credits", usedPercent: pct, resetsAt: nil, kind: .spend))
        }
        return ProviderUsage(provider: "Claude", windows: windows, error: nil)
    }

    private static func fromLimitsArray(_ root: [String: Any]) -> [RateWindow] {
        guard let limits = root["limits"] as? [Any] else { return [] }
        var out: [RateWindow] = []
        for case let item as [String: Any] in limits {
            guard let kind = item["kind"] as? String,
                  let pct = JSON.percent(item["percent"]) else { continue }
            let reset = JSON.date(item["resets_at"])
            switch kind {
            case "session":
                out.append(RateWindow(label: "Session", usedPercent: pct, resetsAt: reset, kind: .session))
            case "weekly_all":
                out.append(RateWindow(label: "Week", usedPercent: pct, resetsAt: reset, kind: .weekly))
            case "weekly_scoped":
                let model = (item["scope"] as? [String: Any])?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String) ?? "model"
                out.append(RateWindow(label: "Week · \(name)", usedPercent: pct, resetsAt: reset, kind: .weeklyScoped))
            default:
                continue // unknown kinds are skipped rather than mislabeled
            }
        }
        return out
    }

    private static func fromLegacyObjects(_ root: [String: Any]) -> [RateWindow] {
        let pairs: [(key: String, label: String)] = [
            ("five_hour", "Session"),
            ("seven_day", "Week"),
            ("seven_day_opus", "Week · Opus"),
        ]
        let kinds: [RateWindow.Kind] = [.session, .weekly, .weeklyScoped]
        var out: [RateWindow] = []
        for (pair, kind) in zip(pairs, kinds) {
            guard let obj = root[pair.key] as? [String: Any],
                  let used = JSON.percent(obj["utilization"]) else { continue }
            out.append(RateWindow(label: pair.label, usedPercent: used,
                                  resetsAt: JSON.date(obj["resets_at"]), kind: kind))
        }
        return out
    }
}

// MARK: Codex

enum CodexDecoder {
    // Confirmed shape (2026-09, GET /backend-api/wham/usage):
    //   rate_limit.primary_window / .secondary_window (either may be null), each:
    //     { used_percent, limit_window_seconds, reset_after_seconds, reset_at }
    //   additional_rate_limits: [ { limit_name?, metered_feature?, primary_window, secondary_window } ] | null
    //   spend_control.individual_limit: { used_percent, remaining_percent, limit, used, unit, reset_at }
    // The window is labeled from its duration (limit_window_seconds), so a
    // weekly-only account reads "Weekly" even though it sits in primary_window.
    static func decode(_ data: Data) throws -> ProviderUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Usage.HTTPError(code: 0, body: "unexpected Codex payload")
        }
        var windows: [RateWindow] = []

        func addWindow(_ obj: [String: Any]?, fallbackLabel: String) {
            guard let obj, let used = JSON.percent(obj["used_percent"]) else { return }
            let seconds = JSON.percent(obj["limit_window_seconds"])
            let label = windowLabel(seconds: seconds, fallback: fallbackLabel)
            let kind: RateWindow.Kind
            switch seconds.map(Int.init) {
            case 604_800: kind = .weekly
            case 18_000: kind = .session
            default: kind = .other
            }
            windows.append(RateWindow(label: label, usedPercent: used, resetsAt: JSON.reset(obj), kind: kind))
        }

        if let rl = root["rate_limit"] as? [String: Any] {
            addWindow(rl["primary_window"] as? [String: Any], fallbackLabel: "Primary")
            addWindow(rl["secondary_window"] as? [String: Any], fallbackLabel: "Secondary")
        }

        // Separately-metered quotas (e.g. per-model), when present.
        for extra in root["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let name = (extra["limit_name"] as? String) ?? (extra["metered_feature"] as? String) ?? "Limit"
            if let p = extra["primary_window"] as? [String: Any], let used = JSON.percent(p["used_percent"]) {
                windows.append(RateWindow(label: name, usedPercent: used, resetsAt: JSON.reset(p)))
            }
        }

        // Spend cap, shown when a real credit limit is configured.
        if let spend = (root["spend_control"] as? [String: Any])?["individual_limit"] as? [String: Any],
           let used = JSON.percent(spend["used_percent"]) {
            windows.append(RateWindow(label: "Spend", usedPercent: used, resetsAt: JSON.reset(spend), kind: .spend))
        }

        return ProviderUsage(provider: "Codex", windows: windows, error: nil)
    }

    private static func windowLabel(seconds: Double?, fallback: String) -> String {
        guard let s = seconds, s > 0 else { return fallback }
        switch Int(s) {
        case 18_000: return "5h"
        case 86_400: return "Daily"
        case 604_800: return "Weekly"
        case 2_592_000: return "Monthly"
        default:
            let hours = Int((s / 3600).rounded())
            return hours >= 48 ? "\(hours / 24)d" : "\(hours)h"
        }
    }
}

// MARK: - Loose JSON helpers

enum JSON {
    /// A percentage that might arrive as 42, 42.0, or "42".
    static func percent(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    private static func iso(_ fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds]
                                     : [.withInternetDateTime]
        return f
    }

    /// A reset instant that might be unix seconds, unix millis, or ISO-8601.
    /// Claude's `resets_at` carries microsecond fractional seconds
    /// (e.g. "2026-09-21T06:00:01.126168+00:00"), which Apple's ISO8601 parser
    /// rejects, so fall back to truncating the fraction to 3 digits.
    static func date(_ value: Any?) -> Date? {
        if let s = value as? String, !s.isEmpty {
            if let d = iso(true).date(from: s) { return d }
            if let d = iso(false).date(from: s) { return d }
            if let t = truncatedFraction(s) {
                if let d = iso(true).date(from: t) { return d }
                if let d = iso(false).date(from: t) { return d }
            }
            if let v = Double(s) { return Date(timeIntervalSince1970: v) }
            return nil
        }
        if let n = value as? NSNumber {
            let v = n.doubleValue
            // Heuristic: seconds vs milliseconds since the epoch.
            return Date(timeIntervalSince1970: v > 1_000_000_000_000 ? v / 1000 : v)
        }
        return nil
    }

    /// Trim fractional seconds to at most 3 digits (".126168+00:00" -> ".126+00:00").
    private static func truncatedFraction(_ s: String) -> String? {
        guard let dot = s.firstIndex(of: ".") else { return nil }
        var end = s.index(after: dot)
        while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
        let digits = s[s.index(after: dot)..<end]
        guard digits.count > 3 else { return nil }
        return String(s[...dot]) + digits.prefix(3) + String(s[end...])
    }

    /// Codex reports an absolute `reset_at` (unix seconds) and a relative
    /// `reset_after_seconds`. Prefer the absolute one; fall back to relative.
    static func reset(_ obj: [String: Any]) -> Date? {
        if let at = date(obj["reset_at"]) { return at }
        if let secs = percent(obj["reset_after_seconds"] ?? obj["resets_in_seconds"]) {
            return Date().addingTimeInterval(secs)
        }
        return date(obj["resets_at"])
    }
}
