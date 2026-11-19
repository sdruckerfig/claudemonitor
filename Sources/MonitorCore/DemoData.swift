#if DEBUG
import Foundation

/// Made-up sample data for the README screenshot (`scripts/screenshot.sh`), so a screenshot never
/// shows the real sessions, folders or worktrees of whoever renders it. Built through the same
/// `Snapshot.assemble` path as live data, so levels, reasons and ordering are computed, not faked.
/// Debug builds only.
public enum DemoData {
    /// - Parameter home: the folder demo paths live under; the UI shows it as `~`.
    public static func snapshot(now: Date, home: String = NSHomeDirectory()) -> Snapshot {
        let gb: UInt64 = 1_073_741_824
        let system = SystemMetrics(
            load: [26.4, 21.8, 17.2], cpuCount: 12, physicalMemoryBytes: 36 * gb,
            memoryPressure: .normal, memoryFreePercent: 41,
            swapUsedBytes: 1_300_000_000, swapTotalBytes: 2 * gb, swapBytesPerSecond: 180_000,
            diskFreeBytes: 214 * 1_073_741_824, thermal: .nominal)

        var rows: [ProcessRow] = []
        func add(_ pid: Int32, _ ppid: Int32, cpu: Double, mb: Int64, minutes: Int, _ path: String, _ args: String) {
            rows.append(ProcessRow(pid: pid, ppid: ppid, cpuPercent: cpu, rssKB: mb * 1024, elapsedSeconds: minutes * 60,
                                   state: "S", executablePath: path, args: args))
        }
        let claude = "/usr/local/bin/claude"
        let node = "/opt/homebrew/bin/node"

        // Sessions: one busy and heavy, one waiting, one idle, one idle for days (stale).
        add(4101, 900, cpu: 6, mb: 520, minutes: 95, claude, "claude")
        add(4310, 4101, cpu: 168, mb: 1_180, minutes: 3, node, "node node_modules/.bin/vitest run --coverage")
        add(4311, 4101, cpu: 31, mb: 430, minutes: 88, node, "node node_modules/.bin/vite --port 5173")
        add(4102, 901, cpu: 0.3, mb: 470, minutes: 52, claude, "claude")
        add(4103, 902, cpu: 0.4, mb: 390, minutes: 260, claude, "claude")
        add(4320, 4103, cpu: 2, mb: 210, minutes: 250, "/opt/homebrew/bin/postgres", "postgres -D /opt/homebrew/var/postgresql")
        add(4104, 903, cpu: 0.1, mb: 310, minutes: 4_400, claude, "claude")

        // Left behind by a session that has since closed.
        add(3901, 1, cpu: 38, mb: 260, minutes: 300, "/bin/zsh",
            "/bin/zsh -c source ~/.claude/shell-snapshots/snapshot-zsh-1.sh && npm run dev")
        add(3902, 3901, cpu: 22, mb: 140, minutes: 300, node, "node node_modules/.bin/next dev")

        // Everything else.
        func app(_ count: Int, from pid: Int32, cpu: Double, mb: Int64, _ path: String) {
            for i in 0..<count {
                add(pid + Int32(i), 1, cpu: cpu, mb: mb, minutes: 600, path, (path as NSString).lastPathComponent)
            }
        }
        app(18, from: 5000, cpu: 7.5, mb: 185, "/Applications/Safari.app/Contents/MacOS/Safari")
        app(6, from: 5100, cpu: 14, mb: 420, "/Applications/Docker.app/Contents/MacOS/com.docker.backend")
        app(9, from: 5200, cpu: 6, mb: 210,
            "/Library/Developer/CoreSimulator/Volumes/iOS/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/launchd_sim")
        app(4, from: 5300, cpu: 3, mb: 160, "/System/Applications/Mail.app/Contents/MacOS/Mail")

        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let code = home + "/code"
        let records = [
            SessionRecord(pid: 4101, sessionId: "5f0c2a71-demo-busy", name: "Checkout redesign", cwd: code + "/storefront",
                          status: .busy, statusUpdatedAt: ago(40), startedAt: ago(95 * 60), waitingFor: nil),
            SessionRecord(pid: 4102, sessionId: "8d13b6e4-demo-wait", name: "Fix flaky login test",
                          cwd: code + "/storefront-login-fix", status: .waiting, statusUpdatedAt: ago(14 * 60),
                          startedAt: ago(52 * 60), waitingFor: "permission to run a command"),
            SessionRecord(pid: 4103, sessionId: "2b7e9f10-demo-idle", name: "API rate limiting", cwd: code + "/api",
                          status: .idle, statusUpdatedAt: ago(2 * 3600), startedAt: ago(260 * 60), waitingFor: nil),
            SessionRecord(pid: 4104, sessionId: "c4a85d39-demo-stale", name: "Docs cleanup", cwd: code + "/docs",
                          status: .idle, statusUpdatedAt: ago(3 * 86400), startedAt: ago(4_400 * 60), waitingFor: nil),
        ]
        return Snapshot.assemble(system: system, processes: rows, records: records, now: now)
    }

    public static func worktreeScan(now: Date, home: String = NSHomeDirectory()) -> WorktreeScan {
        let code = home + "/code"
        let day: TimeInterval = 86400
        func item(_ name: String, repo: String, branch: String, days: Double, bytes: Int64) -> ReclaimableWorktree {
            ReclaimableWorktree(path: code + "/" + name, repo: code + "/" + repo, branch: branch,
                                baseRef: "refs/remotes/origin/main", lastActivity: now.addingTimeInterval(-days * day),
                                sizeBytes: bytes)
        }
        return WorktreeScan(
            finishedAt: now.addingTimeInterval(-12 * 60), duration: 41, repoCount: 6, worktreeCount: 23,
            reclaimable: [
                item("storefront-checkout-v1", repo: "storefront", branch: "feature/checkout-v1", days: 9, bytes: 1_420_000_000),
                item("api-auth-refactor", repo: "api", branch: "auth-refactor", days: 16, bytes: 862_000_000),
                item("storefront-tax-hotfix", repo: "storefront", branch: "hotfix/tax-rounding", days: 4, bytes: 97_000_000),
            ],
            skipped: ["not in origin/main": 7, "has edits": 5, "in use": 4, "recently active": 3, "locked": 1])
    }
}
#endif
