import Foundation
import AgentLimitsCore

// agent-limits: print Claude and Codex rate-limit usage, using the same
// credentials and token cache as the menu bar app.

let usage = """
Usage: agent-limits [claude|codex] [--json]

Shows how much of each subscription's rate-limit windows is used and when
they reset. With no provider, shows both.

Options:
  --json      Print machine-readable JSON instead of a table
  -h, --help  Show this help

Exit status is 1 if any requested provider failed to load.
"""

var json = false
var providers: [String] = []
for arg in CommandLine.arguments.dropFirst() {
    switch arg.lowercased() {
    case "--json": json = true
    case "-h", "--help": print(usage); exit(0)
    case "claude", "codex": providers.append(arg.lowercased())
    default:
        FileHandle.standardError.write(Data("agent-limits: unknown argument '\(arg)'\n\n\(usage)\n".utf8))
        exit(2)
    }
}
if providers.isEmpty { providers = ["claude", "codex"] }

let results: [ProviderUsage] = await withTaskGroup(of: (Int, ProviderUsage).self) { group in
    for (i, name) in providers.enumerated() {
        group.addTask { (i, name == "claude" ? await Usage.fetchClaude() : await Usage.fetchCodex()) }
    }
    var out: [(Int, ProviderUsage)] = []
    for await r in group { out.append(r) }
    return out.sorted { $0.0 < $1.0 }.map(\.1)
}

// A color is only useful on a terminal, and NO_COLOR opts out (no-color.org).
let useColor = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

func tint(_ s: String, _ percent: Double) -> String {
    guard useColor else { return s }
    let code = percent >= 80 ? "31" : percent >= 50 ? "33" : "32" // red / yellow / green
    return "\u{1B}[\(code)m\(s)\u{1B}[0m"
}

func bold(_ s: String) -> String { useColor ? "\u{1B}[1m\(s)\u{1B}[0m" : s }

func padded(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

if json {
    let iso = ISO8601DateFormatter()
    let payload: [[String: Any]] = results.map { p in
        var o: [String: Any] = [
            "provider": p.provider.lowercased(),
            "windows": p.windows.map { w -> [String: Any] in
                var wo: [String: Any] = [
                    "label": w.label,
                    "kind": w.kind.rawValue,
                    "usedPercent": w.usedPercent,
                ]
                if let r = w.resetsAt { wo["resetsAt"] = iso.string(from: r) }
                return wo
            },
        ]
        if let e = p.error { o["error"] = e }
        return o
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    let labelWidth = max(8, results.flatMap(\.windows).map(\.label.count).max() ?? 0)
    for (i, p) in results.enumerated() {
        if i > 0 { print() }
        print(bold(p.provider))
        if let e = p.error {
            print("  \(e)")
        } else if p.windows.isEmpty {
            print("  no active limits")
        } else {
            for w in p.windows {
                let pct = padded("\(Int(w.usedPercent.rounded()))%", 4)
                var line = "  \(padded(w.label, labelWidth))  \(tint(Bar.render(percent: w.usedPercent), w.usedPercent)) \(tint(pct, w.usedPercent))"
                if let r = w.resetsAt { line += "  resets \(Format.relative(r))" }
                print(line)
            }
        }
    }
}

exit(results.contains { $0.error != nil } ? 1 : 0)
