import Foundation

/// Plain-text rendering of a snapshot, for `ClaudeMonitor --print`.
public enum TextReport {
    public static func render(_ s: Snapshot, now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("Hardware: \(word(s.rollup))")
        for r in s.reasons { lines.append("  - \(r)") }
        for m in s.hardware {
            lines.append("  \(dot(m.level)) \(m.title.padding(toLength: 8, withPad: " ", startingAt: 0)) \(m.value)")
        }

        let counts = Dictionary(grouping: s.sessions, by: { $0.usage.record.status.label }).mapValues(\.count)
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        lines.append("")
        lines.append("Claude sessions: \(s.sessions.count)" + (summary.isEmpty ? "" : " (\(summary))"))
        for r in s.sessions {
            let u = r.usage
            let age = r.statusAge.map { " \(Format.duration($0))" } ?? ""
            var line = "  \(dot(r.level)) \(u.record.name) [\(u.record.status.label)\(age)\(r.isStale ? ", stale" : "")]"
            line += "  \(Format.cores(u.totalCores)), \(Format.bytes(u.totalRSSBytes)), pid \(u.process.pid)"
            if let cwd = u.record.cwd { line += "  \(Format.path(cwd))" }
            lines.append(line)
            for why in r.reasons { lines.append("      ! \(why)") }
            for p in u.descendants.prefix(3) where p.cpuPercent >= 5 {
                let det = u.detachedPids.contains(p.pid) ? " (detached)" : ""
                lines.append("      \(p.name): \(Format.cores(p.cores)), \(Format.bytes(p.rssBytes))\(det)")
            }
        }

        if !s.orphans.isEmpty {
            let cores = s.orphans.reduce(0) { $0 + $1.cores }
            let mem = s.orphans.reduce(Int64(0)) { $0 + $1.rssBytes }
            lines.append("")
            lines.append("Left behind by closed sessions: \(s.orphans.count) processes, \(Format.cores(cores)), \(Format.bytes(mem))")
        }

        if !s.otherGroups.isEmpty {
            lines.append("")
            lines.append("Heaviest outside Claude:")
            for g in s.otherGroups {
                lines.append("  \(g.name) ×\(g.count): \(Format.cores(g.cores)), \(Format.bytes(g.rssBytes))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func render(_ scan: WorktreeScan) -> String {
        var lines = ["Checked \(scan.worktreeCount) worktrees in \(scan.repoCount) repos in \(String(format: "%.1f", scan.duration))s."]
        let kept = scan.skipped.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }
        if !kept.isEmpty { lines.append("Kept: " + kept.joined(separator: ", ")) }
        lines.append("Reclaimable: \(scan.reclaimable.count), about \(Format.bytes(scan.totalBytes))")
        for w in scan.reclaimable {
            let age = w.lastActivity.map { ", untouched \(Format.duration(Date().timeIntervalSince($0)))" } ?? ""
            let size = w.sizeBytes.map(Format.bytes) ?? "?"
            lines.append("  \(size.padding(toLength: 8, withPad: " ", startingAt: 0)) \(Format.path(w.path))  [\(w.branch ?? "detached")\(age)]")
        }
        return lines.joined(separator: "\n")
    }

    public static func word(_ l: Level) -> String {
        switch l {
        case .green: return "GREEN (healthy)"
        case .yellow: return "YELLOW (busy)"
        case .red: return "RED (overloaded)"
        }
    }

    static func dot(_ l: Level) -> String {
        switch l {
        case .green: return "🟢"
        case .yellow: return "🟡"
        case .red: return "🔴"
        }
    }
}
