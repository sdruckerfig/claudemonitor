import AppKit
import Foundation
import MonitorCore
import UserNotifications

/// Checks GitHub for a newer release a minute after launch and then once a day (or when asked),
/// tells the user once per version with a notification, and downloads, verifies and opens the
/// installer package when they ask. Installing is the macOS Installer's job: it asks for
/// confirmation (and an administrator password for /Applications), and the package's postinstall
/// starts the new copy, which quits this one.
@MainActor
final class Updater: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        /// Downloading the package, then having Gatekeeper check it.
        case downloading
    }

    @Published private(set) var phase: Phase = .idle
    /// A newer release, once found.
    @Published private(set) var available: AvailableUpdate?
    /// The banner was closed for this version.
    @Published private(set) var dismissed = false
    /// The outcome of the last check or download the user asked for (or of a failed download).
    @Published private(set) var message: String?
    @Published private(set) var lastChecked: Date?

    var onChange: (() -> Void)?
    /// Called when the user clicks the update notification.
    var onOpenRequest: (() -> Void)?

    /// This copy's version; nil for an unbundled build (`swift run`), which never checks.
    let currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    var isEnabled: Bool { currentVersion != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static let interval: TimeInterval = 24 * 3600
    private static let notifiedKey = "notifiedUpdateVersion"
    private static let dismissedKey = "dismissedUpdateVersion"
    private var timer: Timer?

    var showsBanner: Bool { available != nil && !dismissed }

    func start() {
        guard isEnabled else { return }
        UNUserNotificationCenter.current().delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(userInitiated: false) }
        }
        timer?.tolerance = 3600
    }

    func check(userInitiated: Bool) {
        guard isEnabled, let current = currentVersion, phase == .idle else { return }
        phase = .checking
        if userInitiated { message = nil }
        changed()
        Task {
            let result = await UpdateCheck.fetch(current: current)
            phase = .idle
            lastChecked = Date()
            switch result {
            case .success(.upToDate(let latest)):
                available = nil
                if userInitiated {
                    message = AppVersion(latest).flatMap { l in AppVersion(current).map { l <= $0 } } == true
                        ? "Claude Monitor \(current) is the latest version."
                        : "No newer version than \(current) is available."
                }
            case .success(.available(let update)):
                found(update, userInitiated: userInitiated)
            case .failure(let why):
                // A background check fails quietly (offline, rate-limited): the next one retries.
                if userInitiated { message = "Couldn't check for updates: \(why)" }
            }
            changed()
        }
    }

    private func found(_ update: AvailableUpdate, userInitiated: Bool) {
        let isNew = available?.version != update.version
        available = update
        if isNew { message = nil }
        let defaults = UserDefaults.standard
        // Closing the banner hides it for that version only; a user's own check shows it again.
        dismissed = !userInitiated && defaults.string(forKey: Self.dismissedKey) == update.version
        if userInitiated { defaults.removeObject(forKey: Self.dismissedKey) }
        if !userInitiated && defaults.string(forKey: Self.notifiedKey) != update.version {
            defaults.set(update.version, forKey: Self.notifiedKey)
            notify(update)
        }
    }

    func dismiss() {
        guard let v = available?.version else { return }
        UserDefaults.standard.set(v, forKey: Self.dismissedKey)
        dismissed = true
        changed()
    }

    func dismissMessage() {
        message = nil
        changed()
    }

    func openReleaseNotes() {
        if let url = available?.pageURL { NSWorkspace.shared.open(url) }
    }

    // MARK: Notification

    private func notify(_ update: AvailableUpdate) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Claude Monitor \(update.version) is available"
            content.body = "Click to see what's new, then download and install it from the menu bar."
            let request = UNNotificationRequest(identifier: "update-\(update.version)", content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: Download and install

    /// Downloads the package, has Gatekeeper check it is notarized and signed by this app's
    /// developer, then opens it in Installer.
    func downloadAndInstall() {
        guard let update = available, phase == .idle else { return }
        phase = .downloading
        message = nil
        changed()
        let team = PackageVerifier.runningAppTeam()
        Task {
            let outcome = await Self.fetchAndVerify(update, expectedTeam: team)
            phase = .idle
            switch outcome {
            case .failure(let why):
                message = "Couldn't install \(update.version): \(why)"
            case .success(let pkg):
                hand(pkg, update: update)
            }
            changed()
        }
    }

    private nonisolated static func fetchAndVerify(_ update: AvailableUpdate, expectedTeam: String?) async -> Result<URL, UpdateCheck.Failure> {
        let folder: URL
        do {
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            folder = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "ClaudeMonitor").appendingPathComponent("Updates")
            // Older downloads go: only the one being installed is kept.
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failure(.init("no folder to download into (\(error.localizedDescription))"))
        }
        // The name comes from the release; keep only its last component.
        let pkg = folder.appendingPathComponent((update.packageName as NSString).lastPathComponent)
        do {
            var request = URLRequest(url: update.packageURL, timeoutInterval: 120)
            request.setValue("ClaudeMonitor", forHTTPHeaderField: "User-Agent")
            let (temp, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: temp) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .failure(.init("the download failed (HTTP \(status))")) }
            let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value
            if let expected = update.packageBytes, size != expected {
                return .failure(.init("the download is \(size.map(Format.bytes) ?? "?"), not the \(Format.bytes(expected)) GitHub listed"))
            }
            try FileManager.default.moveItem(at: temp, to: pkg)
        } catch {
            return .failure(.init("the download failed (\(error.localizedDescription))"))
        }
        let assessment = PackageVerifier.assess(pkg)
        if let problem = PackageVerifier.problem(with: assessment, expectedTeam: expectedTeam) {
            try? FileManager.default.removeItem(at: pkg)
            return .failure(.init("\(problem). The download was deleted."))
        }
        return .success(pkg)
    }

    /// Opens the verified package in Installer, first explaining the one choice that matters
    /// when this copy lives in ~/Applications.
    private func hand(_ pkg: URL, update: AvailableUpdate) {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
        if Bundle.main.bundleURL.path.hasPrefix(home) {
            let alert = NSAlert()
            alert.messageText = "Install Claude Monitor \(update.version)?"
            alert.informativeText = "The download is notarized by Apple and signed by this app's developer. "
                + "This copy is in ~/Applications. So the update replaces it rather than adding a second copy, "
                + "click Change Install Location… on the Installation Type step and choose Install for me only."
            alert.addButton(withTitle: "Open Installer")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else {
                message = "The update is downloaded: \(Format.path(pkg.path))"
                return
            }
        }
        NSWorkspace.shared.open(pkg)
        message = "Installer is open. When it finishes, Claude Monitor \(update.version) starts and this copy quits."
    }

    private func changed() { onChange?() }

    #if DEBUG
    /// Shows the banner for a made-up release (screenshots only).
    func showDemo(version: String) {
        available = AvailableUpdate(version: version, pageURL: URL(string: "https://example.com")!,
                                    packageURL: URL(string: "https://example.com/ClaudeMonitor-\(version).pkg")!,
                                    packageName: "ClaudeMonitor-\(version).pkg", packageBytes: 1_043_563, notes: nil)
        dismissed = false
    }
    #endif
}

extension Updater: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.dismissed = false
            self.onOpenRequest?()
            self.changed()
        }
        completionHandler()
    }

    /// Shown even while the app is frontmost (the popover is open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
