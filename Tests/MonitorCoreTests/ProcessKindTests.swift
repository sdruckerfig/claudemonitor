import Foundation
import Testing
@testable import MonitorCore

private let home = "/Users/x"

@Test func appsAndMacOSAreNeverDevProcesses() {
    let apps = [
        "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
        "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator",
        "/Users/x/Applications/Thing.app/Contents/MacOS/Thing",
        "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        "/usr/libexec/rapportd",
        "/usr/sbin/cfprefsd",
        "/Library/Developer/CoreSimulator/Volumes/iOS/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/launchd_sim",
    ]
    for path in apps { #expect(ProcessKind.isAppOrSystem(path: path, home: home), "\(path)") }

    let tools = [
        "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
        "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python",
        "/Users/x/Library/Caches/ms-playwright/chromium-1200/chrome-mac/Chromium.app/Contents/MacOS/Chromium",
        "/Users/x/code/app/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron",
        "/Users/x/Library/Developer/Xcode/DerivedData/App-abc/Build/Products/Debug/App.app/Contents/MacOS/App",
        "/opt/homebrew/bin/node",
        "/bin/zsh",
        "/usr/bin/tail",
    ]
    for path in tools { #expect(!ProcessKind.isAppOrSystem(path: path, home: home), "\(path)") }
}

@Test func interactiveShellsAreTellApartFromCommandShells() {
    func shell(_ args: String) -> ProcessRow { row(1, parent: 0, path: String(args.split(separator: " ")[0]), args: args) }
    for args in ["-zsh", "zsh", "/bin/zsh -l", "bash -i", "/bin/bash --login"] {
        #expect(ProcessKind.isInteractiveShell(shell(args)), "\(args)")
    }
    let bashTool = "/bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval 'npm run dev'"
    for args in [bashTool, "zsh -c \"$@\" > \"$0.txt\" 2>&1 /tmp/log make", "zsh -lc 'make test'", "bash scripts/pre-push-check.sh"] {
        #expect(!ProcessKind.isInteractiveShell(shell(args)), "\(args)")
    }
    #expect(!ProcessKind.isInteractiveShell(row(1, parent: 0, path: "/usr/bin/tail", args: "tail -f log")))
    #expect(ProcessKind.isBoundary(row(1, parent: 0, path: "/opt/homebrew/bin/tmux", args: "tmux new -d")))
}

/// Command lines seen on a real machine (paths shortened).
@Test func labelsNameWhatAProcessRuns() {
    let cases: [(path: String, args: String, label: String)] = [
        ("/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python",
         "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python -m http.server 5310 --bind 127.0.0.1",
         "http.server"),
        ("node", "node /Users/x/proj/node_modules/.bin/vite --port 5180 --strictPort", "vite"),
        ("/opt/homebrew/opt/node@24/bin/node", "/opt/homebrew/opt/node@24/bin/node node_modules/vite/bin/vite.js --host 127.0.0.1 --port 5196", "vite"),
        ("node", "node node_modules/@angular/cli/bin/ng serve", "@angular/cli"),
        ("/opt/homebrew/Cellar/node/26.12.1_1/bin/node", "/opt/homebrew/Cellar/node/26.12.1_1/bin/node src/main.ts", "main.ts"),
        ("npm", "npm exec vite --port 5180 --strictPort", "npm exec vite"),
        ("npm", "npm run dev --port 5251", "npm run dev"),
        ("/opt/homebrew/bin/python3", "/opt/homebrew/bin/python3 manage.py runserver", "manage.py"),
        ("/opt/java/bin/java", "/opt/java/bin/java -Xmx4g -cp /Users/x/.gradle/wrapper/dists/gradle-9.6.1/lib/gradle-daemon-main-9.6.1.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 9.6.1",
         "Gradle daemon"),
        ("/opt/java/bin/java", "/opt/java/bin/java -cp /Users/x/.gradle/caches/kotlin.jar -Djava.awt.headless=true org.jetbrains.kotlin.daemon.KotlinCompileDaemon --daemon-autoshutdownIdleSeconds=7200",
         "Kotlin daemon"),
        ("/opt/java/bin/java", "/opt/java/bin/java -jar /Users/x/tools/server.jar --port 8080", "server.jar"),
        ("/opt/java/bin/java", "/opt/java/bin/java -cp app.jar com.example.Main", "Main"),
        ("/opt/homebrew/Cellar/dotnet/10.0.302/libexec/dotnet",
         "/opt/homebrew/Cellar/dotnet/10.0.302/libexec/dotnet /opt/homebrew/Cellar/dotnet/10.0.302/libexec/sdk/10.0.302/MSBuild.dll /noautoresponse /nologo /nodemode:1 /nodeReuse:true /low:false",
         "MSBuild node"),
        ("/opt/homebrew/Cellar/dotnet/10.0.302/libexec/sdk/10.0.302/Roslyn/bincore/VBCSCompiler",
         "/opt/homebrew/Cellar/dotnet/10.0.302/libexec/sdk/10.0.302/Roslyn/bincore/VBCSCompiler -pipename:abc", "C# compiler server"),
        ("/opt/homebrew/Cellar/dotnet/10.0.302/libexec/dotnet",
         "/opt/homebrew/Cellar/dotnet/10.0.302/libexec/dotnet exec /opt/homebrew/Cellar/dotnet/10.0.302/libexec/sdk/10.0.302/vstest.console.dll --framework:.NETCoreApp",
         "vstest.console"),
        ("/opt/homebrew/Cellar/dotnet/10.0.302/libexec/dotnet", "/opt/homebrew/Cellar/dotnet/10.0.302/libexec/dotnet test api/Tests.csproj", "dotnet test"),
        ("node", "node /Users/x/proj/node_modules/esbuild/bin/esbuild --service=0.25.0 --ping", "esbuild service"),
        ("-zsh", "-zsh", "zsh"),
        ("/usr/bin/tail", "tail -n +1 -f /tmp/log.txt", "tail"),
    ]
    for c in cases {
        #expect(ProcessKind.label(row(1, parent: 0, path: c.path, args: c.args)) == c.label, "\(c.args)")
    }
}

@Test func buildToolsIncludeDaemonsAndWatchers() {
    let yes = [
        row(1, parent: 0, path: "/opt/java/bin/java", args: "java -cp x.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 9.6.1"),
        row(2, parent: 0, path: "node", args: "node /p/node_modules/.bin/tsc --watch"),
        row(3, parent: 0, path: "/usr/bin/make", args: "make -j8"),
        row(4, parent: 0, path: "/opt/homebrew/bin/cargo", args: "cargo build"),
    ]
    for p in yes { #expect(ProcessKind.isBuildTool(p), "\(p.args)") }
    let no = [
        row(5, parent: 0, path: "/usr/bin/tail", args: "tail -f log"),
        row(6, parent: 0, path: "/usr/bin/python3", args: "python3 -m http.server 8000"),
        row(7, parent: 0, path: "/usr/bin/ssh-agent", args: "/usr/bin/ssh-agent -l"),
    ]
    for p in no { #expect(!ProcessKind.isBuildTool(p), "\(p.args)") }
}
