import Darwin
import Foundation
import Testing
@testable import MonitorCore

/// A `KERN_PROCARGS2` buffer: argc, executable path, padding, arguments, environment.
private func procargs(argc: Int32, exec: String, args: [String], env: [String]) -> [UInt8] {
    var buf = withUnsafeBytes(of: argc) { Array($0) }
    buf += Array(exec.utf8) + [0, 0, 0, 0]
    for a in args { buf += Array(a.utf8) + [0] }
    for e in env { buf += Array(e.utf8) + [0] }
    return buf + [0, 0]
}

private let keys: Set<String> = [ProcessInspector.sessionIdKey, ProcessInspector.claudePidKey]

@Test func readsOnlyTheRequestedEnvironmentVariables() throws {
    let buf = procargs(argc: 2, exec: "/usr/bin/python3", args: ["python3", "-m"], env: [
        "PATH=/usr/bin",
        "CLAUDE_CODE_MESSAGING_TOKEN=secret",
        "CLAUDE_CODE_SESSION_ID=685901e8-1764-441f-97ce-5d648dcccfd4",
        "CLAUDE_PID=19031",
        "CLAUDE_PIDX=1",
        "XCLAUDE_PID=2",
    ])
    let env = try #require(ProcessInspector.parseEnvironment(buf[...], keys: keys))
    #expect(env == ["CLAUDE_CODE_SESSION_ID": "685901e8-1764-441f-97ce-5d648dcccfd4", "CLAUDE_PID": "19031"])
}

@Test func malformedProcargsAreRejectedNotMisread() {
    #expect(ProcessInspector.parseEnvironment([1, 0][...], keys: keys) == nil)
    // argc says 5 arguments but the buffer ends first: the strings that follow aren't environment.
    let short = procargs(argc: 5, exec: "/bin/sh", args: ["sh", "CLAUDE_PID=1"], env: [])
    #expect(ProcessInspector.parseEnvironment(short[...], keys: keys) == nil)
    // An argument that looks like a variable is not one.
    let lookalike = procargs(argc: 2, exec: "/bin/sh", args: ["sh", "CLAUDE_PID=1"], env: ["HOME=/Users/x"])
    #expect(ProcessInspector.parseEnvironment(lookalike[...], keys: keys) == [:])
}

@Test func readsThisProcesssEnvironmentFolderAndPorts() throws {
    let pid = getpid()
    if let home = ProcessInfo.processInfo.environment["HOME"] {
        #expect(ProcessInspector.environment(of: pid, keys: ["HOME"])?["HOME"] == home)
    }
    let cwd = try #require(ProcessInspector.cwd(pid))
    #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    try withUnsafeMutablePointer(to: &addr) { p in
        try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            try #require(bind(fd, sa, len) == 0)
            try #require(getsockname(fd, sa, &len) == 0)
        }
    }
    let port = UInt16(bigEndian: addr.sin_port)
    #expect(!ProcessInspector.listeningPorts(pid).contains(port))   // bound, not listening yet
    try #require(listen(fd, 1) == 0)
    #expect(ProcessInspector.listeningPorts(pid).contains(port))
}

@Test func enrichMarksOnlyTheUsersOwnProcesses() throws {
    let me = row(getpid(), parent: 1, path: "/usr/bin/swift", args: "swift test", mine: false)
    let launchd = row(1, parent: 0, path: "/sbin/launchd", args: "/sbin/launchd", mine: false)
    let rows = ProcessInspector().enrich([me, launchd])
    #expect(rows[0].details.ownedByUser)
    #expect(rows[0].details.imagePath != nil)
    #expect(!rows[1].details.ownedByUser)
}

@Test func parsesLaunchctlList() {
    let text = "PID\tStatus\tLabel\n49545\t-9\tcom.apple.progressd\n-\t0\tcom.apple.idle\n930\t0\thomebrew.mxcl.postgresql@16\n"
    #expect(LaunchdJobs.parse(text) == [49545, 930])
}
