import AppKit
import Foundation
import MonitorCore
import ServiceManagement

/// Samples on background queues and publishes results to the UI.
/// Health refreshes every 5 s; the worktree scan runs every 30 min.
@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    /// Sampling errors; cleared by the next successful sample.
    @Published private(set) var errorText: String?
    /// The outcome of something the user did (End Session, launch at login). Stays until
    /// dismissed or replaced, so the 5-second refresh doesn't wipe it.
    @Published private(set) var notice: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    @Published private(set) var worktreeScan: WorktreeScan?
    @Published private(set) var scanningWorktrees = false
    @Published private(set) var deletingWorktrees: Set<String> = []
    @Published private(set) var worktreeMessage: String?

    /// Root pids of jobs being stopped.
    @Published private(set) var stoppingJobs: Set<Int32> = []

    // View state lives here: SwiftUI's @State is a macro that Command Line Tools cannot expand.
    @Published var expandedSessions: Set<Int32> = []
    @Published var showLeftovers = true
    @Published var showServices = false
    @Published var showWorktrees = true

    var onUpdate: (() -> Void)?

    private let monitor = Monitor()
    private let scanner = WorktreeScanner()
    private let queue = DispatchQueue(label: "claudemonitor.sampler", qos: .utility)
    private let worktreeQueue = DispatchQueue(label: "claudemonitor.worktrees", qos: .background)
    private var timers: [Timer] = []
    private var inFlight = false

    static let interval: TimeInterval = 5
    static let worktreeInterval: TimeInterval = 30 * 60

    func start() {
        refresh()
        schedule(every: Self.interval) { $0.refresh() }
        // Let the first health sample land before the heavier worktree scan.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.scanWorktrees() }
        schedule(every: Self.worktreeInterval) { $0.scanWorktrees() }
    }

    private func schedule(every seconds: TimeInterval, _ action: @escaping (MonitorModel) -> Void) {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
        }
        timer.tolerance = seconds * 0.1
        timers.append(timer)
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let monitor = monitor
        queue.async {
            let result = Result { try monitor.snapshot() }
            DispatchQueue.main.async {
                self.inFlight = false
                switch result {
                case .success(let s):
                    self.snapshot = s
                    self.errorText = nil
                case .failure(let e):
                    self.errorText = "\(e)"
                }
                self.onUpdate?()
            }
        }
    }

    func dismissNotice() {
        notice = nil
        onUpdate?()
    }

    /// Launch at login can change outside the app (System Settings, or `--login-item` from any
    /// copy, since every copy shares the bundle ID). Called when the popover opens.
    func refreshLoginItem() {
        let on = SMAppService.mainApp.status == .enabled
        if on != launchAtLogin { launchAtLogin = on }
    }

    func setLaunchAtLogin(_ on: Bool) {
        let prefix = "Launch at login: "
        do {
            if on {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {   // already off: nothing to undo
                try SMAppService.mainApp.unregister()
            }
            if notice?.hasPrefix(prefix) == true { notice = nil }   // an earlier failure no longer applies
        } catch {
            notice = prefix + error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        onUpdate?()
    }

    #if DEBUG
    /// Shows `DemoData` instead of live data (for `--render-screenshots`). Don't call `start()` as well.
    func showDemo(now: Date) {
        snapshot = DemoData.snapshot(now: now)
        worktreeScan = DemoData.worktreeScan(now: now)
        showServices = true
        launchAtLogin = true
        errorText = nil
        notice = nil
    }
    #endif

    func toggleExpanded(_ pid: Int32) {
        if expandedSessions.contains(pid) { expandedSessions.remove(pid) } else { expandedSessions.insert(pid) }
    }

    // MARK: Worktrees

    func scanWorktrees() {
        guard !scanningWorktrees, deletingWorktrees.isEmpty else { return }
        scanningWorktrees = true
        let scanner = scanner
        worktreeQueue.async {
            let scan = scanner.scan()
            DispatchQueue.main.async {
                self.scanningWorktrees = false
                self.worktreeScan = scan
                self.onUpdate?()
            }
        }
    }

    /// Confirms, then removes each worktree after re-checking it is still safe.
    func confirmDelete(_ items: [ReclaimableWorktree]) {
        guard !items.isEmpty else { return }
        let total = items.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        let alert = NSAlert()
        alert.messageText = items.count == 1
            ? "Delete worktree “\((items[0].path as NSString).lastPathComponent)”?"
            : "Delete \(items.count) worktrees?"
        var info = "Frees about \(Format.bytes(total)). Each one is clean, idle, and fully contained in its repo's \(items[0].baseName). "
        info += "Every check runs again just before deleting, and git refuses to remove a worktree that has edits. Branches are kept.\n\n"
        info += items.prefix(12).map { "• \(Format.path($0.path))  (\($0.sizeBytes.map(Format.bytes) ?? "?"))" }.joined(separator: "\n")
        if items.count > 12 { info += "\n…and \(items.count - 12) more" }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: items.count == 1 ? "Delete" : "Delete \(items.count)")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        delete(items)
    }

    private func delete(_ items: [ReclaimableWorktree]) {
        deletingWorktrees.formUnion(items.map(\.path))
        worktreeMessage = nil
        let scanner = scanner
        // Same serial queue as scans, but the user is waiting: don't run git throttled.
        // .enforceQoS: without it the queue's background QoS wins over the block's.
        worktreeQueue.async(qos: .userInitiated, flags: .enforceQoS) {
            var removed = Set<String>()
            var freed: Int64 = 0
            var failures: [String] = []
            var savedMessages: [String] = []
            for item in items {
                do {
                    savedMessages += try scanner.remove(item)
                    removed.insert(item.path)
                    freed += item.sizeBytes ?? 0
                } catch {
                    failures.append("\(error)")
                }
            }
            DispatchQueue.main.async {
                self.deletingWorktrees.subtract(items.map(\.path))
                // Refused ones go too: the re-check just found them unsafe. The next scan relists
                // any that become reclaimable again.
                self.worktreeScan = self.worktreeScan?.removing(Set(items.map(\.path)))
                var msg = removed.isEmpty ? "" : "Deleted \(removed.count) worktree(s), about \(Format.bytes(freed)) freed."
                if let folder = savedMessages.first.map({ ($0 as NSString).deletingLastPathComponent }) {
                    msg += " Saved \(savedMessages.count) unsent commit message(s) to \(Format.path(folder))."
                }
                if !failures.isEmpty { msg += (msg.isEmpty ? "" : " ") + failures.joined(separator: "; ") }
                self.worktreeMessage = msg
                self.onUpdate?()
            }
        }
    }

    // MARK: Session actions

    func revealFolder(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func resumeCommand(_ r: SessionRecord) -> String? {
        guard let id = r.sessionId else { return nil }
        let cd = r.cwd.map { "cd \(shellQuote($0)) && " } ?? ""
        return "\(cd)claude --resume \(id)"
    }

    /// Asks for confirmation, then sends SIGTERM to the session's claude process, after making
    /// sure the pid still belongs to that same process (pids are reused once a process exits).
    func confirmTerminate(_ u: SessionUsage) {
        let pid = u.process.pid
        guard let snap = snapshot,
              let row = snap.sessions.first(where: { $0.usage.process.pid == pid })?.usage.process,
              ProcessIdentity.isSameProcess(row, takenAt: snap.takenAt),
              let started = ProcessIdentity.startTime(of: pid) else {
            notice = "“\(u.record.name)” has already ended."
            refresh()
            return
        }
        let alert = NSAlert()
        alert.messageText = "End session “\(u.record.name)”?"
        var info = "Sends SIGTERM to claude (pid \(pid))."
        if !u.descendants.isEmpty {
            info += " \(u.descendants.count) process(es) it started may keep running or exit with it."
        }
        if let cmd = resumeCommand(u.record) { info += "\n\nResume later with:\n\(cmd)" }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The dialog may have been open a long time: check again right before signalling.
        let unchanged = ProcessIdentity.startTime(of: pid) == started
            && SessionFiles.load().contains { $0.pid == pid && $0.sessionId == u.record.sessionId }
        guard unchanged else {
            notice = "“\(u.record.name)” ended while the dialog was open; nothing was sent."
            refresh()
            return
        }
        if kill(pid, SIGTERM) != 0 {
            notice = "Could not end pid \(pid): \(String(cString: strerror(errno)))"
        } else {
            notice = nil
        }
        refresh()
    }

    // MARK: Stopping processes

    /// Asks for confirmation, then stops each job: SIGTERM (or SIGKILL when `force`) to every
    /// process in it that is still the same process, and to anything it started since.
    /// `takenAt` dates the jobs' rows: the snapshot they were shown from, which may be older
    /// than `snapshot` by now.
    func confirmStop(_ jobs: [ProcessJob], takenAt: Date, force: Bool = false) {
        guard !jobs.isEmpty else { return }
        let count = jobs.reduce(0) { $0 + $1.members.count }
        let signalName = force ? "SIGKILL" : "SIGTERM"
        let alert = NSAlert()
        let verb = force ? "Force stop" : "Stop"
        if jobs.count == 1 {
            alert.messageText = "\(verb) \(jobs[0].name)?"
        } else {
            alert.messageText = "\(verb) \(jobs.count) process groups?"
        }
        var info = "Sends \(signalName) to \(count == 1 ? "1 process" : "\(count) processes")"
        if jobs.count == 1 {
            let j = jobs[0]
            switch j.owner {
            case .session(_, let name): info += " started by session “\(name)”, which may still be using it"
            case .closedSession: info += " left behind by a closed Claude session"
            case .detached: info += " running on \(count == 1 ? "its" : "their") own (whatever started \(count == 1 ? "it" : "them") has exited)"
            case .launcher(let name): info += " started from \(name)"
            }
            info += ":\n\n" + j.members.prefix(8).map { "• \($0.pid)  \(Self.shorten($0.args))" }.joined(separator: "\n")
            if j.members.count > 8 { info += "\n…and \(j.members.count - 8) more" }
            if let cwd = j.cwd { info += "\n\nFolder: \(Format.path(cwd))" }
        } else {
            let lines = jobs.prefix(12).map { (j: ProcessJob) -> String in
                let folder: String = j.cwd.map { "  " + Format.path($0) } ?? ""
                return "• \(j.title), pid \(j.root.pid)\(folder)"
            }
            info += ":\n\n" + lines.joined(separator: "\n")
            if jobs.count > 12 { info += "\n…and \(jobs.count - 12) more" }
        }
        info += force
            ? "\n\nSIGKILL can't be caught: they get no chance to clean up (temporary files, locks, child processes)."
            : "\n\nEach process is checked again just before the signal is sent."
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: force ? "Force Stop" : (jobs.count == 1 ? "Stop" : "Stop \(jobs.count)"))
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stop(jobs, takenAt: takenAt, signal: force ? SIGKILL : SIGTERM)
    }

    /// A process in a session's tree, with everything under it, as a job to stop; nil if it
    /// can't be stopped (claude itself, an interactive shell, an app, someone else's process).
    func job(for process: ProcessRow, in u: SessionUsage) -> ProcessJob? {
        guard Jobs.isStoppable(process) else { return nil }
        var members = [process]
        var queue = [process.pid]
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            for c in u.descendants where c.ppid == pid && !members.contains(where: { $0.pid == c.pid }) && Jobs.isStoppable(c) {
                members.append(c)
                queue.append(c.pid)
            }
        }
        return ProcessJob(roots: [process], members: members, owner: .session(pid: u.process.pid, name: u.record.name),
                          label: ProcessKind.label(process),
                          ports: Set(members.flatMap(\.details.listeningPorts)).sorted(), cwd: process.details.cwd)
    }

    private func stop(_ jobs: [ProcessJob], takenAt: Date, signal: Int32) {
        let roots = Set(jobs.map(\.id))
        stoppingJobs.formUnion(roots)
        let monitor = monitor
        let queue = queue
        let what = jobs.count == 1 ? jobs[0].title : "\(jobs.count) process groups"
        let members = jobs.flatMap(\.members)
        // The sampler's queue: `Monitor` is used from that one queue. The user is waiting, so
        // don't run throttled (.enforceQoS: otherwise the queue's utility QoS wins).
        queue.async(qos: .userInitiated, flags: .enforceQoS) {
            let freshAt = Date()
            let outcome: ProcessStopper.Outcome
            do {
                let fresh = try monitor.processTable(takenAt: freshAt)
                let plan = ProcessStopper.plan(members: members, takenAt: takenAt, fresh: fresh, freshTakenAt: freshAt)
                outcome = ProcessStopper.send(signal, to: plan, takenAt: freshAt)
            } catch {
                DispatchQueue.main.async { self.finishStop(roots, notice: "Could not stop \(what): \(error)") }
                return
            }
            // Give them a moment to exit, then see what's left.
            queue.asyncAfter(deadline: .now() + (outcome.signalled.isEmpty ? 0 : 2)) {
                let left = ProcessStopper.stillRunning(outcome.signalled, takenAt: freshAt)
                let notice = Self.stopNotice(what: what, signal: signal, outcome: outcome, stillRunning: left)
                DispatchQueue.main.async { self.finishStop(roots, notice: notice) }
            }
        }
    }

    private func finishStop(_ roots: Set<Int32>, notice: String?) {
        stoppingJobs.subtract(roots)
        self.notice = notice
        refresh()
    }

    nonisolated static func stopNotice(what: String, signal: Int32, outcome: ProcessStopper.Outcome,
                                       stillRunning left: [ProcessRow]) -> String? {
        func count(_ n: Int) -> String { n == 1 ? "1 process" : "\(n) processes" }
        let sent = outcome.signalled.count
        var parts: [String] = []
        if sent == 0 && outcome.failed.isEmpty {
            parts.append("Nothing to stop: \(what) had already exited.")
        } else if sent > 0 && left.isEmpty {
            parts.append("\(signal == SIGKILL ? "Force-stopped" : "Stopped") \(what).")
        } else if sent > 0 {
            let names = left.prefix(3).map { "\($0.name) \($0.pid)" }.joined(separator: ", ")
            parts.append("Sent \(signal == SIGKILL ? "SIGKILL" : "SIGTERM") to \(count(sent)); \(left.count) still running (\(names)).")
            if signal != SIGKILL { parts.append("Right-click to Force Stop.") }
        }
        if let (row, why) = outcome.failed.first {
            parts.append("Could not signal \(row.name) \(row.pid): \(why)" + (outcome.failed.count > 1 ? " (and \(outcome.failed.count - 1) more)." : "."))
        }
        return parts.joined(separator: " ")
    }

    func open(port: UInt16) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    nonisolated static func shorten(_ s: String, max: Int = 90) -> String {
        guard s.count > max else { return s }
        let half = (max - 1) / 2
        return String(s.prefix(half)) + "…" + String(s.suffix(half))
    }

    private func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) }
            ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
