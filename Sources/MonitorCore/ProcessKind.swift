import Foundation

/// Rules about what kind of process a row is: an app or part of macOS, a shell or terminal
/// multiplexer that must never be stopped as part of something else, a build tool, and a
/// readable label ("vite", "http.server", "Gradle daemon").
public enum ProcessKind {
    // MARK: Apps and macOS

    /// Part of macOS, or of an installed app (in /Applications, ~/Applications, /System or
    /// /Library). Never listed, never stopped, and never attributed to a session through its
    /// environment: an app a session happened to launch (Docker Desktop) belongs to the user.
    ///
    /// Not apps: Xcode's command-line tools (Xcode.app/Contents/Developer/…), Python.app inside
    /// a Python framework, and app bundles anywhere else (a Playwright Chromium in ~/Library/Caches,
    /// Electron in node_modules, a build in DerivedData), which are things being built or tested.
    public static func isAppOrSystem(path: String, home: String = NSHomeDirectory()) -> Bool {
        for prefix in ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"] where path.hasPrefix(prefix) {
            return true
        }
        if path.contains("/CoreSimulator/") || path.contains(".simruntime/") { return true }
        guard let app = path.range(of: ".app/") else { return false }
        let bundle = path[..<app.lowerBound]
        let installed = ["/Applications/", home + "/Applications/", "/Library/"].contains { bundle.hasPrefix($0) }
            && !bundle.hasPrefix("/Library/Developer/CommandLineTools/")
        guard installed else { return false }
        let rest = path[app.upperBound...]
        // xcodebuild, swift-frontend… live in Xcode.app/Contents/Developer; Simulator.app there is an app.
        if rest.hasPrefix("Contents/Developer/") && !rest.contains(".app/") { return false }
        return true
    }

    public static func isAppOrSystem(_ p: ProcessRow, home: String = NSHomeDirectory()) -> Bool {
        isAppOrSystem(path: p.details.imagePath ?? p.executablePath, home: home)
    }

    // MARK: Boundaries

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish"]
    /// Hosts of other people's work: stopping one would take unrelated sessions or windows with it.
    static let hosts: Set<String> = ["tmux", "screen", "zellij", "abduco", "dtach", "mosh-server", "sshd", "login", "su", "sudo"]

    /// A shell someone is typing into: a login shell (`-zsh`), or one with no command or script.
    /// The shells Claude Code's Bash tool runs (`zsh -c …`) are not interactive.
    public static func isInteractiveShell(_ p: ProcessRow) -> Bool {
        let tokens = p.args.split(separator: " ")
        guard let argv0 = tokens.first else { return false }
        let base = String((argv0 as Substring).split(separator: "/").last ?? argv0)
        let name = base.hasPrefix("-") ? String(base.dropFirst()) : base
        guard shells.contains(name) else { return false }
        if base.hasPrefix("-") { return true }
        for t in tokens.dropFirst() {
            if !t.hasPrefix("-") { return false }                         // a script
            if t == "-i" || t == "--interactive" { return true }
            if !t.hasPrefix("--") && t.dropFirst().contains("c") { return false }   // -c, -lc
        }
        return true   // only options, or none
    }

    /// Never stopped as part of a job, and a job never reaches past one: an interactive shell or
    /// something that hosts other sessions (tmux, screen, sshd, login, sudo).
    public static func isBoundary(_ p: ProcessRow) -> Bool {
        hosts.contains(p.name) || isInteractiveShell(p)
    }

    /// Wrappers that only start the real work (`zsh -c`, `npm run`, `lockf`): a job is named after
    /// what they run, not after them.
    static let wrappers: Set<String> = shells.union(["env", "npm", "npx", "pnpm", "yarn", "lockf", "nohup", "timeout",
                                                     "gtimeout", "caffeinate", "xargs", "tee", "time", "nice", "arch"])

    public static func isWrapper(_ p: ProcessRow) -> Bool {
        wrappers.contains(stripLoginDash(p.name))
    }

    // MARK: Build tools

    static let buildTools: Set<String> = [
        "make", "gmake", "ninja", "cmake", "xcodebuild", "swift-build", "swift-frontend", "swift-driver", "swiftc",
        "clang", "clang++", "ld", "cargo", "rustc", "go", "gradle", "gradlew", "mvn", "sbt", "bazel", "bazelisk",
        "buck2", "buck2d", "sccache", "esbuild", "esbuild service", "tsc", "turbo", "nx", "webpack", "rollup",
        "parcel", "jest", "vitest", "nodemon", "tsx", "ts-node", "msbuild", "Gradle daemon", "Gradle worker",
        "Kotlin daemon", "MSBuild node", "C# compiler server", "Razor compiler server", "vstest.console", "testhost",
        "dotnet build", "dotnet test", "dotnet watch", "dotnet msbuild",
    ]

    /// A compiler, build driver, test runner, watcher, or one of the daemons they leave running
    /// to make the next build faster (Gradle, Kotlin, MSBuild nodes, the C# compiler server).
    public static func isBuildTool(_ p: ProcessRow) -> Bool {
        buildTools.contains(label(p)) || buildTools.contains(p.name) || p.args.contains(" --watch")
    }

    // MARK: Labels

    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "Python", "ruby", "php", "perl", "java", "dotnet"]

    /// A short name for what the process is running: the script or package an interpreter runs
    /// (`node …/node_modules/.bin/vite` is "vite", `python -m http.server` is "http.server"), a
    /// known daemon's name, or the executable's name.
    public static func label(_ p: ProcessRow) -> String {
        let args = p.args
        if args.contains("GradleDaemon") { return "Gradle daemon" }
        if args.contains("GradleWorkerMain") { return "Gradle worker" }
        if args.contains("KotlinCompileDaemon") { return "Kotlin daemon" }
        if args.contains("MSBuild.dll") && args.lowercased().contains("nodemode:") { return "MSBuild node" }
        if args.contains("VBCSCompiler") { return "C# compiler server" }
        if args.contains("rzc.dll") || args.contains("Microsoft.NET.Sdk.Razor") && args.contains(" server") { return "Razor compiler server" }
        if args.contains("esbuild") && args.contains("--service") { return "esbuild service" }

        let tokens = args.split(separator: " ").map(String.init)
        let name = stripLoginDash(p.name.isEmpty ? (tokens.first.map(basename) ?? "pid \(p.pid)") : p.name)
        let rest = Array(tokens.dropFirst())
        let base = name.hasPrefix("python") ? "python" : name

        switch base {
        case "python", "Python":
            if let m = rest.firstIndex(of: "-m"), m + 1 < rest.count { return rest[m + 1] }
            return firstOperand(rest).map(basename) ?? name
        case "java":
            if let j = rest.firstIndex(of: "-jar"), j + 1 < rest.count { return basename(rest[j + 1]) }
            let withValue: Set<String> = ["-cp", "-classpath", "--class-path", "-p", "--module-path"]
            var i = 0
            while i < rest.count {
                let t = rest[i]
                if withValue.contains(t) { i += 2; continue }
                if !t.hasPrefix("-") { return String(t.split(separator: ".").last ?? Substring(t)) }
                i += 1
            }
            return name
        case "dotnet":
            if let dll = rest.first(where: { $0.hasSuffix(".dll") }) {
                return (basename(dll) as NSString).deletingPathExtension
            }
            return firstOperand(rest).map { "dotnet \($0)" } ?? name
        case "npm", "npx", "pnpm", "yarn", "bun", "deno":
            let words = rest.filter { !$0.hasPrefix("-") }.prefix(2)
            if base == "bun" || base == "deno", let script = words.first, script.contains("/") || script.contains(".") {
                return basename(script)
            }
            return ([name] + words).joined(separator: " ")
        case "node", "ruby", "php", "perl":
            guard let script = firstOperand(rest) else { return name }
            return packageName(script) ?? basename(script)
        default:
            return name
        }
    }

    /// `…/node_modules/.bin/vite` and `node_modules/vite/bin/vite.js` are "vite"; scoped packages keep their scope.
    static func packageName(_ path: String) -> String? {
        guard let r = path.range(of: "node_modules/", options: .backwards) else { return nil }
        let parts = path[r.upperBound...].split(separator: "/").map(String.init)
        guard let first = parts.first else { return nil }
        if first == ".bin" { return parts.count > 1 ? parts[1] : nil }
        if first.hasPrefix("@"), parts.count > 1 { return first + "/" + parts[1] }
        return first
    }

    static func firstOperand(_ tokens: [String]) -> String? {
        tokens.first { !$0.hasPrefix("-") }
    }

    static func basename(_ s: String) -> String { (s as NSString).lastPathComponent }

    static func stripLoginDash(_ s: String) -> String { s.hasPrefix("-") ? String(s.dropFirst()) : s }
}
