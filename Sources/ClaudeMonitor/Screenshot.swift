#if DEBUG
import AppKit
import SwiftUI

/// Renders the popover with `DemoData` to screenshot-light.png and screenshot-dark.png in `directory`
/// (debug builds only; run by `scripts/screenshot.sh`). It never creates a menu bar item, so a
/// running copy of the app is left alone.
@MainActor
func renderScreenshots(into directory: URL, height: CGFloat = 1_030) throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date()
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let model = MonitorModel()
        model.showDemo(now: now)
        let size = NSSize(width: 480, height: height)
        let look = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: StatusView(model: model, height: height)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = look

        // SwiftUI only draws AppKit-backed controls (buttons, checkboxes, scroll views) in a window.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = look
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Dynamic colors resolve against the current drawing appearance, not the view's.
        (look ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let url = directory.appendingPathComponent("screenshot-\(name).png")
        try png.write(to: url)
        print("Wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
    }
}
#endif
