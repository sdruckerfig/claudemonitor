import Foundation
import Security

/// A dotted version ("0.1.4", "v0.2"), compared number by number. Anything after a "-" or "+"
/// (a pre-release or build suffix) is ignored.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = s[..<cut] }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        components = parts.map { $0! }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.components.count, b.components.count) {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// A newer release on GitHub, with its installer package.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let pageURL: URL
    public let packageURL: URL
    public let packageName: String
    public let packageBytes: Int64?
    /// The release notes, as written (Markdown).
    public let notes: String?

    public init(version: String, pageURL: URL, packageURL: URL, packageName: String, packageBytes: Int64?, notes: String?) {
        self.version = version
        self.pageURL = pageURL
        self.packageURL = packageURL
        self.packageName = packageName
        self.packageBytes = packageBytes
        self.notes = notes
    }
}

/// Checks the project's GitHub releases for a newer version. Sends nothing about this Mac or its
/// user: one unauthenticated request for the latest release.
public enum UpdateCheck {
    public static let repository = "sdruckerfig/claudemonitor"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Packages are only downloaded from the project's own release downloads.
    public static let downloadPrefix = "https://github.com/\(repository)/releases/download/"

    public enum Outcome: Equatable, Sendable {
        case upToDate(latest: String)
        case available(AvailableUpdate)
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Reads a GitHub "latest release" response. A newer version without an installer package
    /// (or with one hosted anywhere but this project's release downloads) isn't offered.
    public static func parse(_ data: Data, current: String) -> Result<Outcome, Failure> {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, let latest = AppVersion(tag) else {
            return .failure(Failure("GitHub's answer has no release version"))
        }
        guard let mine = AppVersion(current) else { return .failure(Failure("this copy's version (\(current)) can't be read")) }
        if obj["draft"] as? Bool == true || obj["prerelease"] as? Bool == true || latest <= mine {
            return .success(.upToDate(latest: latest.description))
        }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        let packages = assets.compactMap { a -> (name: String, url: URL, size: Int64?)? in
            guard let name = a["name"] as? String, name.lowercased().hasSuffix(".pkg"),
                  let link = a["browser_download_url"] as? String, link.hasPrefix(downloadPrefix),
                  let url = URL(string: link) else { return nil }
            return (name, url, (a["size"] as? NSNumber)?.int64Value)
        }
        let expected = "ClaudeMonitor-\(latest.description).pkg"
        guard let pkg = packages.first(where: { $0.name == expected }) ?? packages.first else {
            return .failure(Failure("version \(latest) has no installer package yet"))
        }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")!
        let notes = (obj["body"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return .success(.available(AvailableUpdate(version: latest.description, pageURL: page, packageURL: pkg.url,
                                                   packageName: pkg.name, packageBytes: pkg.size, notes: notes)))
    }

    /// Asks GitHub for the latest release.
    public static func fetch(current: String, session: URLSession = .shared) async -> Result<Outcome, Failure> {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeMonitor/\(current)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .failure(Failure("GitHub answered HTTP \(status)")) }
            return parse(data, current: current)
        } catch {
            return .failure(Failure(error.localizedDescription))
        }
    }
}

/// Decides whether a downloaded installer package may be opened, from Gatekeeper's assessment
/// (`spctl --assess --type install`): it must be accepted, notarized by Apple, and signed by the
/// same developer team as the running app.
public enum PackageVerifier {
    public struct Assessment: Equatable, Sendable {
        public let accepted: Bool
        /// Gatekeeper's `source=`, e.g. "Notarized Developer ID".
        public let source: String?
        /// Gatekeeper's `origin=`, e.g. "Developer ID Installer: Jane Doe (AB12CD34EF)".
        public let origin: String?

        public var notarized: Bool { source?.hasPrefix("Notarized") == true }
        /// The team ID in parentheses at the end of `origin`.
        public var teamId: String? {
            guard let o = origin, o.hasSuffix(")"), let open = o.lastIndex(of: "(") else { return nil }
            let id = o[o.index(after: open)..<o.index(before: o.endIndex)]
            return id.isEmpty ? nil : String(id)
        }
    }

    /// Parses `spctl -a -vv -t install <pkg>` output (it writes to stderr) and exit status.
    public static func parse(_ output: String, status: Int32) -> Assessment {
        var source: String?
        var origin: String?
        var verdict = false
        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("source=") { source = String(line.dropFirst("source=".count)) }
            else if line.hasPrefix("origin=") { origin = String(line.dropFirst("origin=".count)) }
            else if line.hasSuffix(": accepted") { verdict = true }
        }
        return Assessment(accepted: status == 0 && verdict, source: source, origin: origin)
    }

    /// Runs Gatekeeper's assessment of `url`.
    public static func assess(_ url: URL) -> Assessment {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        task.arguments = ["--assess", "-vv", "--type", "install", url.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return Assessment(accepted: false, source: nil, origin: nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self), status: task.terminationStatus)
    }

    /// Why the package must not be opened, or nil when it may be. `expectedTeam` is the running
    /// app's team; nil for a copy built from source, which has none to compare (then any
    /// notarized Developer ID package from the project's release downloads is accepted).
    public static func problem(with a: Assessment, expectedTeam: String?) -> String? {
        guard a.accepted else { return "macOS Gatekeeper rejected it" + (a.source.map { " (\($0))" } ?? "") }
        guard a.notarized else { return "it isn't notarized by Apple" + (a.source.map { " (\($0))" } ?? "") }
        if let expectedTeam, a.teamId != expectedTeam {
            return "it's signed by \(a.origin ?? "an unknown developer"), not by this app's developer (team \(expectedTeam))"
        }
        return nil
    }

    /// The developer team that signed the running app; nil when it's unsigned or ad hoc signed.
    public static func runningAppTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
