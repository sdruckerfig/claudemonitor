import AppKit
import MonitorCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MonitorModel()
    private let updater = Updater()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimMenuBar() else {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
        }
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: StatusView(model: model, updater: updater))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 480, height: 640)

        model.onUpdate = { [weak self] in self?.updateButton() }
        updater.onChange = { [weak self] in self?.updateButton() }
        updater.onOpenRequest = { [weak self] in self?.showPopover() }
        updateButton()
        model.start()
        updater.start()
    }

    /// One menu bar icon. The copy launched last wins (an update, or a copy installed elsewhere)
    /// and asks the others, including ones with the old bundle ID, to quit. Ties go to the higher
    /// pid, so two copies started at the same moment still leave exactly one. Returns false when
    /// this copy should quit instead.
    private func claimMenuBar() -> Bool {
        // An unbundled build (swift run, .build/debug) leaves installed copies alone.
        guard let myID = Bundle.main.bundleIdentifier else { return true }
        let me = NSRunningApplication.current
        let ids = Set([myID, "io.github.sdruckerfig.claudemonitor", "local.claudemonitor"])
        let others = ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        if others.contains(where: { Self.launched($0, after: me) }) { return false }
        for other in others {
            other.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !other.isTerminated { other.forceTerminate() }
            }
        }
        return true
    }

    /// Compares kernel process start times (launchDate is nil for a copy not started through
    /// LaunchServices). Pids only break exact ties: they wrap, so they don't order launches.
    private static func launched(_ a: NSRunningApplication, after b: NSRunningApplication) -> Bool {
        let ta = ProcessIdentity.startTime(of: a.processIdentifier) ?? a.launchDate
        let tb = ProcessIdentity.startTime(of: b.processIdentifier) ?? b.launchDate
        if let ta, let tb, ta != tb { return ta > tb }
        return a.processIdentifier > b.processIdentifier
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.refresh()
        model.refreshLoginItem()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let snapshot = model.snapshot
        let level = snapshot?.rollup
        button.image = Self.dot(level.map(LevelStyle.nsColor) ?? .tertiaryLabelColor)
        let count = snapshot?.sessions.count ?? 0
        let needsYou = snapshot?.sessions.filter { $0.usage.record.status == .waiting }.count ?? 0
        var title = needsYou > 0 ? " \(count) · \(needsYou)⏳" : " \(count)"
        if updater.showsBanner { title += " ↑" }
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
        ])

        var tip = "Claude Monitor"
        if let s = snapshot {
            tip = "Hardware: \(TextReport.word(s.rollup))\n\(s.sessions(of: .claude).count) Claude sessions"
            if s.codexInstalled { tip += ", \(s.sessions(of: .codex).count) Codex threads" }
            for r in s.reasons { tip += "\n• \(r)" }
            if !s.leftovers.isEmpty {
                let mem = s.leftovers.reduce(Int64(0)) { $0 + $1.totalRSSBytes }
                tip += "\n\(s.leftovers.count) left behind by closed sessions (\(Format.bytes(mem)))"
            }
        }
        if let w = model.worktreeScan, !w.reclaimable.isEmpty {
            tip += "\n\(w.reclaimable.count) worktrees can be deleted (about \(Format.bytes(w.totalBytes)))"
        }
        if let u = updater.available, updater.showsBanner { tip += "\nClaude Monitor \(u.version) is available" }
        if let e = model.errorText { tip += "\n⚠︎ \(e)" }
        if let n = model.notice { tip += "\n\(n)" }
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
    }

    /// A colored status dot. Not a template image, so the menu bar keeps its color.
    static func dot(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            circle.lineWidth = 0.75
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

enum LevelStyle {
    static func nsColor(_ l: Level) -> NSColor {
        switch l {
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .red: return .systemRed
        }
    }

    static func color(_ l: Level) -> Color { Color(nsColor: nsColor(l)) }

    /// Orange dark enough for text on the light popover (≈4.7:1), light enough on the dark one.
    static let readableOrange = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.70, blue: 0.35, alpha: 1)
            : NSColor(srgbRed: 0.54, green: 0.26, blue: 0.0, alpha: 1)
    })

    static func headline(_ l: Level) -> String {
        switch l {
        case .green: return "Hardware healthy"
        case .yellow: return "Hardware busy"
        case .red: return "Hardware overloaded"
        }
    }
}
