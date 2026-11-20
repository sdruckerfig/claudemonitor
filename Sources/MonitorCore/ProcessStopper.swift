import Darwin
import Foundation

/// Stops jobs. Planning is pure (and tested); signalling re-checks every process just before
/// the signal, because pids are reused once a process exits.
public enum ProcessStopper {
    public struct Outcome: Sendable {
        /// Processes the signal was sent to.
        public var signalled: [ProcessRow] = []
        /// Processes skipped because they had exited, or their pid now belongs to something else.
        public var gone: [ProcessRow] = []
        /// Processes the signal couldn't be sent to, with the reason.
        public var failed: [(ProcessRow, String)] = []
    }

    /// What to signal to stop `members` (a job's processes as of a snapshot taken at `takenAt`),
    /// worked out against a fresh process table taken at `freshTakenAt`: each member that is
    /// still the same process, plus everything it has started since, root first. Never includes
    /// anything `Jobs.isStoppable` rules out, and never reaches past one.
    public static func plan(members: [ProcessRow], takenAt: Date, fresh: [ProcessRow], freshTakenAt: Date,
                            selfPid: Int32 = getpid()) -> [ProcessRow] {
        let byPid = Dictionary(fresh.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for p in fresh where p.pid != p.ppid { children[p.ppid, default: []].append(p.pid) }

        var out: [ProcessRow] = []
        var seen = Set<Int32>()
        for m in members {
            guard !seen.contains(m.pid), let now = byPid[m.pid],
                  isSame(m, takenAt: takenAt, as: now, takenAt: freshTakenAt),
                  Jobs.isStoppable(now, selfPid: selfPid) else { continue }
            var queue = [now]
            seen.insert(now.pid)
            while !queue.isEmpty {
                let p = queue.removeFirst()
                out.append(p)
                for c in children[p.pid] ?? [] where !seen.contains(c) {
                    seen.insert(c)
                    if let row = byPid[c], Jobs.isStoppable(row, selfPid: selfPid) { queue.append(row) }
                }
            }
        }
        return out
    }

    /// Whether two `ps` rows describe the same process: same pid, and start times that agree to
    /// within `ps`'s one-second resolution, plus slack.
    public static func isSame(_ a: ProcessRow, takenAt ta: Date, as b: ProcessRow, takenAt tb: Date) -> Bool {
        a.pid == b.pid && abs(a.startTime(takenAt: ta).timeIntervalSince(b.startTime(takenAt: tb))) < 3
    }

    /// Sends `signal` to each process in `rows` (from a table taken at `takenAt`) that is still
    /// that process and still the user's. A stopped (suspended) process is also continued, so it
    /// can act on SIGTERM.
    public static func send(_ signal: Int32, to rows: [ProcessRow], takenAt: Date) -> Outcome {
        var outcome = Outcome()
        let uid = getuid()
        for row in rows {
            guard ProcessIdentity.isSameProcess(row, takenAt: takenAt),
                  let info = ProcessInspector.bsdInfo(row.pid), info.uid == uid else {
                outcome.gone.append(row)
                continue
            }
            if kill(row.pid, signal) == 0 {
                if signal == SIGTERM && row.state.hasPrefix("T") { kill(row.pid, SIGCONT) }
                outcome.signalled.append(row)
            } else if errno == ESRCH {
                outcome.gone.append(row)
            } else {
                outcome.failed.append((row, String(cString: strerror(errno))))
            }
        }
        return outcome
    }

    /// The processes in `rows` (from a table taken at `takenAt`) that are still running. One that
    /// has exited but whose parent hasn't collected its exit status yet (a zombie) isn't.
    public static func stillRunning(_ rows: [ProcessRow], takenAt: Date) -> [ProcessRow] {
        rows.filter { ProcessIdentity.isSameProcess($0, takenAt: takenAt) && ProcessInspector.bsdInfo($0.pid)?.zombie == false }
    }
}
