import Darwin
import Foundation

/// Reads what `ps` doesn't show, straight from the kernel: who owns each process, its real
/// executable, its working folder, the TCP ports it listens on, and two variables from its
/// environment (`CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`). The rest of the environment, which can
/// hold tokens and keys, is never kept: only those two names are compared and copied.
///
/// Apps and macOS's own processes are left alone (see `ProcessKind.isAppOrSystem`), as are
/// other users' processes, which the kernel doesn't let us read anyway.
///
/// Not thread-safe (it caches per process): use from one serial queue.
public final class ProcessInspector {
    public static let sessionIdKey = "CLAUDE_CODE_SESSION_ID"
    public static let claudePidKey = "CLAUDE_PID"

    /// Per process: what doesn't change until it execs something else (its executable, its
    /// starting environment). A fork keeps its start time across exec, so the command line is
    /// part of the key too.
    private struct Fixed {
        let start: Date
        let args: String
        let imagePath: String?
        let skip: Bool
        let sessionId: String?
        let claudePid: Int32?
    }

    private var fixed: [Int32: Fixed] = [:]
    private let uid = getuid()
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    /// Fills in `details` for every row the current user owns.
    public func enrich(_ rows: [ProcessRow]) -> [ProcessRow] {
        var seen = Set<Int32>()
        let out = rows.map { row -> ProcessRow in
            seen.insert(row.pid)
            guard let info = Self.bsdInfo(row.pid), info.uid == uid else { return row }
            let f: Fixed
            if let cached = fixed[row.pid], cached.start == info.start, cached.args == row.args {
                f = cached
            } else {
                let image = Self.imagePath(row.pid)
                let skip = ProcessKind.isAppOrSystem(path: image ?? row.executablePath, home: home)
                let env = skip ? [:] : (Self.environment(of: row.pid, keys: [Self.sessionIdKey, Self.claudePidKey]) ?? [:])
                f = Fixed(start: info.start, args: row.args, imagePath: image, skip: skip,
                          sessionId: env[Self.sessionIdKey].flatMap { $0.isEmpty ? nil : $0 },
                          claudePid: env[Self.claudePidKey].flatMap { Int32($0) })
                fixed[row.pid] = f
            }
            var r = row
            r.details.ownedByUser = true
            r.details.imagePath = f.imagePath
            guard !f.skip else { return r }
            r.details.claudeSessionId = f.sessionId
            r.details.claudePid = f.claudePid
            r.details.cwd = Self.cwd(row.pid)
            r.details.listeningPorts = Self.listeningPorts(row.pid)
            return r
        }
        fixed = fixed.filter { seen.contains($0.key) }
        return out
    }

    // MARK: libproc

    static func bsdInfo(_ pid: Int32) -> (uid: uid_t, start: Date, zombie: Bool)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let start = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        return (info.pbi_uid, start, info.pbi_status == UInt32(SZOMB))
    }

    static func imagePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    public static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// TCP ports `pid` is listening on, ascending.
    public static func listeningPorts(_ pid: Int32) -> [UInt16] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 32)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var ports = Set<UInt16>()
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            ports.insert(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
        }
        return ports.sorted()
    }

    // MARK: Environment

    /// The values of `keys` in `pid`'s environment (as it was when the process started), or nil
    /// if it can't be read. Other variables are skipped without being copied.
    public static func environment(of pid: Int32, keys: Set<String>) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        defer { buf.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return parseEnvironment(buf[0..<size], keys: keys)
    }

    /// Parses a `KERN_PROCARGS2` buffer: argc (Int32), the executable path, NUL padding, argc
    /// argument strings, then `NAME=value` environment strings up to an empty string.
    public static func parseEnvironment(_ buf: ArraySlice<UInt8>, keys: Set<String>) -> [String: String]? {
        guard buf.count >= 4 else { return nil }
        var i = buf.startIndex
        let argc = buf[i..<(i + 4)].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        i += 4
        func skipString() { while i < buf.endIndex, buf[i] != 0 { i += 1 } }
        skipString()                                         // executable path
        while i < buf.endIndex, buf[i] == 0 { i += 1 }       // padding
        var n: Int32 = 0
        while i < buf.endIndex, n < argc {                   // arguments
            skipString()
            i += 1
            n += 1
        }
        guard i <= buf.endIndex, n == argc else { return nil }
        let wanted = Set(keys.map { Array($0.utf8) + [UInt8(ascii: "=")] })
        var out: [String: String] = [:]
        while i < buf.endIndex, buf[i] != 0 {
            let start = i
            skipString()
            let entry = buf[start..<i]
            if let prefix = wanted.first(where: { entry.starts(with: $0) }) {
                let name = String(decoding: prefix.dropLast(), as: UTF8.self)
                out[name] = String(decoding: entry.dropFirst(prefix.count), as: UTF8.self)
            }
            i += 1
        }
        return out
    }
}

/// Processes launchd runs as jobs in the user's domain (Homebrew services, login agents). They're
/// meant to run on their own, so they're never listed as leftovers or stopped.
public enum LaunchdJobs {
    /// Their pids, from `launchctl list`; nil if that fails (then nothing counts as detached).
    public static func pids() -> Set<Int32>? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses `launchctl list` (`PID<tab>Status<tab>Label`, "-" when not running).
    public static func parse(_ text: String) -> Set<Int32> {
        Set(text.split(separator: "\n").compactMap { line in
            line.split(separator: "\t", maxSplits: 1).first.flatMap { Int32($0) }
        })
    }
}
