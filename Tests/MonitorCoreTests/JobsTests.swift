import Foundation
import Testing
@testable import MonitorCore

private let terminal = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
private let codeHelper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
private let docker = "/Applications/Docker.app/Contents/MacOS/com.docker.backend"
private let python = "/opt/homebrew/bin/python3"
private let java = "/opt/java/bin/java"
private let dotnet = "/opt/homebrew/bin/dotnet"
private let bashTool = "/bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'npm run dev'"
private let gradle = "java -cp gradle.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 9.6.1"
private let msbuild = "dotnet /sdk/MSBuild.dll /nologo /nodemode:1 /nodeReuse:true"

/// The shapes seen on a real machine: a live session with a dev server and detached build
/// daemons, what closed sessions left behind, and servers and daemons from outside Claude.
private let processes: [ProcessRow] = [
    row(1, parent: 0, path: "/sbin/launchd", mine: false),
    row(815, parent: 1, path: terminal),
    row(816, parent: 815, path: "/usr/bin/login", args: "login -pf x", mine: false),
    row(817, parent: 816, path: "/bin/zsh", args: "-zsh"),
    // Live session "web" and its dev server: zsh -c → npm → node vite (listening) → esbuild.
    row(900, parent: 817, path: "claude", args: "claude", elapsed: 10_000),
    row(901, parent: 900, path: "/bin/zsh", args: bashTool, session: "live-1"),
    row(902, parent: 901, path: "npm", args: "npm run dev", session: "live-1"),
    row(903, parent: 902, path: "node", args: "node /w/node_modules/.bin/vite --port 5180", ports: [5180], cwd: "/w/client", session: "live-1"),
    row(904, parent: 903, path: "node", args: "node /w/node_modules/esbuild/bin/esbuild --service=0.25 --ping", session: "live-1"),
    // ...and the build daemons it detached: Gradle with its Kotlin daemon, and MSBuild nodes.
    row(950, parent: 1, rssMB: 900, path: java, args: gradle, ports: [51237], cwd: "/Users/x/.gradle/daemon", session: "live-1"),
    row(951, parent: 950, path: java, args: "java org.jetbrains.kotlin.daemon.KotlinCompileDaemon", ports: [17884], session: "live-1"),
    row(960, parent: 1, path: dotnet, args: msbuild, cwd: "/sdk", session: "live-1"),
    row(961, parent: 1, path: dotnet, args: msbuild, cwd: "/sdk", session: "live-1"),
    row(962, parent: 1, path: dotnet, args: msbuild, cwd: "/sdk", session: "live-1"),
    // After /clear: a new session id in the record, but CLAUDE_PID still names claude 900.
    row(970, parent: 1, path: "/usr/bin/tail", args: "tail -f build.log", elapsed: 600, session: "pre-clear", claudePid: 900),
    // An app the session launched is the user's.
    row(980, parent: 1, path: docker, ports: [1435], session: "live-1"),

    // Left behind by a closed session: a server found by its environment, and a watcher
    // found by its command line.
    row(700, parent: 1, path: python, args: "python3 -m http.server 5310", ports: [5310], cwd: "/p/build", session: "dead-1"),
    row(710, parent: 1, path: "/bin/zsh", args: "/bin/zsh -c source /Users/x/.claude/shell-snapshots/old.sh && tail -f log"),
    row(711, parent: 710, path: "/usr/bin/tail", args: "tail -f log", cwd: "/p/logs"),
    // A closed session started tmux: the dev server in it is a leftover, tmux and its shell aren't.
    row(770, parent: 1, path: "/opt/homebrew/bin/tmux", args: "tmux new -d", session: "dead-1"),
    row(771, parent: 770, path: "/bin/zsh", args: "-zsh", session: "dead-1"),
    row(772, parent: 771, path: "npm", args: "npm start", session: "dead-1"),
    row(773, parent: 772, path: "node", args: "node server.js", ports: [4000], session: "dead-1"),
    // A headless `claude -p` (no session file) is still running: what it started isn't left behind.
    row(790, parent: 1, path: "claude", args: "claude -p summarize", elapsed: 300),
    row(791, parent: 1, path: "/usr/bin/tail", args: "tail -f out", elapsed: 200, session: "headless-1", claudePid: 790),
    // CLAUDE_PID names claude 900, but this process is older than it: that was another claude.
    row(795, parent: 1, path: "/usr/bin/tail", args: "tail -f old", elapsed: 20_000, cwd: "/q", session: "gone-2", claudePid: 900),

    // Outside Claude.
    row(720, parent: 1, rssMB: 600, path: python, args: "python3 -m http.server 8000", ports: [8000], cwd: "/srv"),   // detached
    row(730, parent: 1, path: "/opt/homebrew/bin/postgres", args: "postgres -D /var/pg", ports: [5432]),    // launchd job
    row(731, parent: 730, path: "/opt/homebrew/bin/node", args: "node worker.js", ports: [5433]),        // under it
    row(740, parent: 1, path: codeHelper),
    row(741, parent: 740, path: "/bin/zsh", args: "/bin/zsh -l"),
    row(742, parent: 741, path: "npm", args: "npm run dev"),
    row(743, parent: 742, path: "node", args: "node node_modules/.bin/next dev", ports: [3000], cwd: "/n"),
    row(780, parent: 1, path: python, args: "python3 -m http.server 9000", ports: [9000], mine: false),     // another user's
    row(785, parent: 1, path: "/usr/bin/ssh-agent", args: "/usr/bin/ssh-agent -l"),                       // neither
]

private let records = [record(900, id: "live-1", name: "web", status: .busy)]
private let launchd: Set<Int32> = [815, 730]

private func build(launchdJobs: Set<Int32>? = launchd) -> (Attribution, [ProcessJob], [ProcessJob]) {
    let a = Attribution.build(processes: processes, records: records)
    let jobs = Jobs.build(a, processes: processes, launchdJobs: launchdJobs, selfPid: 99_999)
    return (a, jobs.leftovers, jobs.services)
}

@Test func environmentTiesDetachedJobsToTheirSession() throws {
    let (a, _, _) = build()
    let web = try #require(a.sessions.first)
    let pids = Set(web.descendants.map(\.pid))
    #expect(pids.isSuperset(of: [901, 902, 903, 904, 950, 951, 960, 961, 962, 970]))
    #expect(!pids.contains(980))                  // Docker stays the user's
    #expect(!pids.contains(795))                  // an older process: CLAUDE_PID meant another claude
    #expect(web.detachedPids.isSuperset(of: [950, 951, 970]))
}

@Test func leftoversAreWhatClosedSessionsLeftBehind() throws {
    let (_, leftovers, _) = build()
    #expect(Set(leftovers.map(\.root.pid)) == [700, 710, 772, 795])
    let server = try #require(leftovers.first { $0.root.pid == 700 })
    #expect(server.label == "http.server")
    #expect(server.ports == [5310])
    #expect(server.cwd == "/p/build")
    #expect(server.owner == .closedSession)
    let watcher = try #require(leftovers.first { $0.root.pid == 710 })
    #expect(watcher.members.map(\.pid) == [710, 711])
    #expect(watcher.label == "tail")             // named after what the shell runs
    let tmuxed = try #require(leftovers.first { $0.root.pid == 772 })
    #expect(tmuxed.members.map(\.pid) == [772, 773])   // not tmux, not the shell inside it
    #expect(leftovers.first?.ports.isEmpty == false)   // servers first
}

@Test func servicesAreServersAndDetachedBuildDaemons() throws {
    let (_, _, services) = build()
    let byRoot = Dictionary(uniqueKeysWithValues: services.map { ($0.root.pid, $0) })
    #expect(Set(byRoot.keys) == [901, 950, 960, 720, 742])

    let vite = try #require(byRoot[901])          // climbs from the listener to the Bash tool's shell
    #expect(vite.members.map(\.pid) == [901, 902, 903, 904])
    #expect(vite.label == "vite")
    #expect(vite.ports == [5180])
    #expect(vite.owner == .session(pid: 900, name: "web"))

    let gradleJob = try #require(byRoot[950])
    #expect(gradleJob.members.map(\.pid) == [950, 951])
    #expect(gradleJob.label == "Gradle daemon")
    #expect(gradleJob.ports == [17884, 51237])

    let msbuildJob = try #require(byRoot[960])
    #expect(msbuildJob.roots.map(\.pid) == [960, 961, 962])
    #expect(msbuildJob.name == "MSBuild node ×3")

    #expect(byRoot[720]?.owner == .detached)
    let next = try #require(byRoot[742])          // not the interactive shell above it
    #expect(next.members.map(\.pid) == [742, 743])
    #expect(next.owner == .launcher("Visual Studio Code"))
}

@Test func withoutLaunchdInformationNothingCountsAsDetached() {
    let (_, leftovers, services) = build(launchdJobs: nil)
    #expect(Set(services.map(\.root.pid)) == [901, 950, 960, 742])
    #expect(leftovers.count == 4)
}

@Test func neverStoppableAreClaudeAppsShellsAndOtherUsers() {
    #expect(!Jobs.isStoppable(row(900, parent: 1, path: "claude"), selfPid: 1))
    #expect(!Jobs.isStoppable(row(980, parent: 1, path: docker), selfPid: 1))
    #expect(!Jobs.isStoppable(row(817, parent: 1, path: "/bin/zsh", args: "-zsh"), selfPid: 1))
    #expect(!Jobs.isStoppable(row(770, parent: 1, path: "/opt/homebrew/bin/tmux", args: "tmux"), selfPid: 1))
    #expect(!Jobs.isStoppable(row(780, parent: 1, path: python, mine: false), selfPid: 1))
    #expect(!Jobs.isStoppable(row(1, parent: 0, path: "/sbin/launchd"), selfPid: 2))
    #expect(!Jobs.isStoppable(row(42, parent: 1, path: "/usr/bin/tail"), selfPid: 42))
    #expect(Jobs.isStoppable(row(42, parent: 1, path: "/usr/bin/tail"), selfPid: 1))
}

@Test func snapshotDoesNotCountListedServicesAsOutsideApps() {
    let s = Snapshot.assemble(system: metrics(), processes: processes, records: records, launchdJobs: launchd, now: fixedNow)
    #expect(s.leftovers.count == 4)
    #expect(s.services.count == 5)
    #expect(!s.otherGroups.contains { $0.name == "python3" })   // 720 (600 MB) is listed as a service
}
