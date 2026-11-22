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

        let code = home + "/code"
        var rows: [ProcessRow] = []
        func add(_ pid: Int32, _ ppid: Int32, cpu: Double, mb: Int64, minutes: Int, _ path: String, _ args: String,
                 ports: [UInt16] = [], cwd: String? = nil, session: String? = nil, codexThread: String? = nil) {
            rows.append(ProcessRow(pid: pid, ppid: ppid, cpuPercent: cpu, rssKB: mb * 1024, elapsedSeconds: minutes * 60,
                                   state: "S", executablePath: path, args: args,
                                   details: ProcessDetails(ownedByUser: true, cwd: cwd, listeningPorts: ports,
                                                           claudeSessionId: session, codexThreadId: codexThread)))
        }
        let claude = "/usr/local/bin/claude"
        let node = "/opt/homebrew/bin/node"

        // Sessions: one busy and heavy, one waiting, one idle, one idle for days (stale).
        add(4101, 900, cpu: 6, mb: 520, minutes: 95, claude, "claude")
        add(4310, 4101, cpu: 168, mb: 1_180, minutes: 3, node, "node node_modules/.bin/vitest run --coverage")
        add(4311, 4101, cpu: 31, mb: 430, minutes: 88, node, "node node_modules/.bin/vite --port 5173",
            ports: [5173], cwd: code + "/storefront")
        add(4102, 901, cpu: 0.3, mb: 470, minutes: 52, claude, "claude")
        add(4103, 902, cpu: 0.4, mb: 390, minutes: 260, claude, "claude")
        add(4320, 4103, cpu: 2, mb: 210, minutes: 250, "/opt/homebrew/bin/postgres", "postgres -D /opt/homebrew/var/postgresql",
            ports: [5432], cwd: code + "/api")
        add(4104, 903, cpu: 0.1, mb: 310, minutes: 4_400, claude, "claude")

        // A Codex thread in the Codex app's server; its subagent is running the test suite.
        let codexServer = "/Applications/Codex.app/Contents/Resources/codex"
        add(4500, 1, cpu: 3, mb: 380, minutes: 300, codexServer, codexServer + " app-server")
        add(4510, 4500, cpu: 0, mb: 6, minutes: 6, "/bin/zsh", "/bin/zsh -lc pytest -n 4", codexThread: "01a1f0c3-demo-sub")
        add(4511, 4510, cpu: 92, mb: 640, minutes: 6, "/opt/homebrew/bin/python3", "python3 -m pytest -n 4",
            cwd: code + "/ml-pipeline", codexThread: "01a1f0c3-demo-sub")

        // Left behind by sessions that have since closed: a dev server found by its command
        // line, and a static file server found by its environment.
        add(3901, 1, cpu: 38, mb: 260, minutes: 300, "/bin/zsh",
            "/bin/zsh -c source ~/.claude/shell-snapshots/snapshot-zsh-1.sh && npm run dev", cwd: code + "/landing")
        add(3902, 3901, cpu: 22, mb: 140, minutes: 300, node, "node node_modules/.bin/next dev",
            ports: [3000], cwd: code + "/landing")
        add(3950, 1, cpu: 0, mb: 18, minutes: 3 * 1_440, "/opt/homebrew/bin/python3", "python3 -m http.server 8000",
            ports: [8000], cwd: code + "/docs/site", session: "0e7d55c2-demo-closed")

        // A build daemon running on its own after the build that started it (outside Claude).
        add(3990, 1, cpu: 0.2, mb: 1_150, minutes: 140, "/opt/homebrew/opt/openjdk/bin/java",
            "java -Xmx4g -cp gradle-daemon-main-9.6.1.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 9.6.1",
            cwd: home + "/.gradle/daemon/9.6.1")

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
            SessionRecord(agent: .codex, pid: 4500, sessionId: "01a1f0c2-demo-codex", name: "Migrate the feature store",
                          cwd: code + "/ml-pipeline", status: .busy, statusUpdatedAt: ago(8), startedAt: ago(300 * 60),
                          waitingFor: nil, threadIds: ["01a1f0c2-demo-codex", "01a1f0c3-demo-sub"]),
        ]
        return Snapshot.assemble(system: system, processes: rows, records: records, launchdJobs: [], now: now,
                                 codexInstalled: true)
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
