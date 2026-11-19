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

    // View state lives here: SwiftUI's @State is a macro that Command Line Tools cannot expand.
    @Published var expandedSessions: Set<Int32> = []
    @Published var showOrphans = false
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

    private func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) }
            ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
