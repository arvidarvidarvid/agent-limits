import Foundation

// MARK: - Small formatting helpers

public enum Bar {
    public static func render(percent: Double, width: Int = 10) -> String {
        let clamped = max(0, min(100, percent))
        let filled = Int((clamped / 100 * Double(width)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }
}

public enum Format {
    public static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    public static func relative(_ date: Date, relativeTo now: Date = Date()) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return "now" }
        let minutes = Int(remaining / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "in \(days)d \(hours % 24)h" }
        if hours > 0 { return "in \(hours)h \(minutes % 60)m" }
        if minutes > 0 { return "in \(minutes)m" }
        return "in <1m"
    }
}
