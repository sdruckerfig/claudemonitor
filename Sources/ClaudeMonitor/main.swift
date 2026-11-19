import AppKit
import MonitorCore
import ServiceManagement

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write("claudemonitor: \(message)\n".data(using: .utf8)!)
    exit(code)
}

let usage = """
usage: ClaudeMonitor                              run the menu bar app
       ClaudeMonitor --print                      print one health snapshot and exit
       ClaudeMonitor --worktrees                  list reclaimable worktrees and exit (never deletes)
       ClaudeMonitor --login-item [on|off|status] manage launch at login (run from inside the .app)
       ClaudeMonitor --version
       ClaudeMonitor --help
"""

let arguments = CommandLine.arguments

// Parse once, and run exactly what was parsed. Unknown arguments are rejected instead of
// silently starting a second menu bar app, and so is more than one mode. macOS itself may pass
// -psn_<n>_<n>, or -NS…/-Apple… settings followed by a value, to a GUI app; only those exact
// shapes are allowed, and their values are never read as modes.
func isSystemSetting(_ arg: String) -> Bool {
    for prefix in ["-NS", "-Apple"] where arg.hasPrefix(prefix) {
        let name = arg.dropFirst(prefix.count)
        return !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    return false
}
func isProcessSerial(_ arg: String) -> Bool {
    guard arg.hasPrefix("-psn_") else { return false }
    let parts = arg.dropFirst(5).split(separator: "_", omittingEmptySubsequences: false)
    return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
}

var modes: [String] = []
var loginAction = "status"
var screenshotDirectory = ""   // --render-screenshots (debug builds only)
do {
    var i = 1
    while i < arguments.count {
        let arg = arguments[i]
        let next = arguments.indices.contains(i + 1) ? arguments[i + 1] : nil
        switch arg {
        case "--print", "--worktrees", "--version":
            modes.append(arg)
        case "--help", "-h":
            modes.append("--help")
        case "--login-item":
            modes.append(arg)
            if let next, ["on", "off", "status"].contains(next) { loginAction = next; i += 1 }
        #if DEBUG
        case "--render-screenshots":
            guard let next, !next.hasPrefix("-") else { fail("--render-screenshots needs a folder", code: 2) }
            modes.append(arg)
            screenshotDirectory = next
            i += 1
        #endif
        case _ where isProcessSerial(arg):
            break
        case _ where isSystemSetting(arg):
            guard next != nil else { fail("\(arg) needs a value\n\(usage)", code: 2) }
            i += 1
        default:
            fail("unknown argument: \(arg)\n\(usage)", code: 2)
        }
        i += 1
    }
    if modes.count > 1 {
        let distinct = modes.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        fail((distinct.count > 1 ? "use one of \(distinct.joined(separator: ", ")) at a time"
                                 : "\(modes[0]) was given more than once") + "\n\(usage)", code: 2)
    }
}

switch modes.first {
case "--help"?:
    print(usage)
    exit(0)

case "--version"?:
    print("Claude Monitor \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(unbundled build)")")
    exit(0)

case "--print"?:
    // One health snapshot as text. Two samples a couple of seconds apart so swap throughput has a delta.
    let monitor = Monitor()
    do {
        _ = try monitor.snapshot()
        Thread.sleep(forTimeInterval: 2)
        print(TextReport.render(try monitor.snapshot()))
        exit(0)
    } catch {
        fail("\(error)")
    }

case "--worktrees"?:
    // Lists reclaimable worktrees; never deletes.
    print(TextReport.render(WorktreeScanner().scan()))
    exit(0)

case "--login-item"?:
    // Must be run from inside the installed .app bundle; used by install.sh and uninstall.sh.
    let service = SMAppService.mainApp
    func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval (System Settings → General → Login Items)"
        case .notFound: return "not found (run this from inside the installed ClaudeMonitor.app)"
        @unknown default: return "unknown"
        }
    }
    switch loginAction {
    case "on":
        do { try service.register() } catch { fail("could not enable launch at login: \(error.localizedDescription)") }
    case "off":
        // Unregistering something that was never registered is not an error for our purposes.
        if service.status != .notRegistered {
            do { try service.unregister() } catch { fail("could not disable launch at login: \(error.localizedDescription)") }
        }
    default:
        break
    }
    print("Launch at login: \(describe(service.status))")
    exit(0)

#if DEBUG
case "--render-screenshots"?:
    // README screenshots from made-up data: scripts/screenshot.sh.
    MainActor.assumeIsolated {
        do { try renderScreenshots(into: URL(fileURLWithPath: screenshotDirectory)) } catch { fail("\(error)") }
    }
    exit(0)
#endif

default:
    break
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
