import Foundation
import Testing
@testable import MonitorCore

@Test func versionsCompareNumberByNumber() throws {
    func v(_ s: String) throws -> AppVersion { try #require(AppVersion(s)) }
    #expect(try v("0.1.10") > v("0.1.9"))
    #expect(try v("v0.2") > v("0.1.4"))
    #expect(try v("0.1.4") == v("v0.1.4"))
    #expect(try v("0.1") == v("0.1.0"))
    #expect(try v("1.0.0-beta.2") == v("1.0.0"))
    #expect(try v("v0.1.4").description == "0.1.4")
    #expect(AppVersion("") == nil)
    #expect(AppVersion("latest") == nil)
    #expect(AppVersion("1..2") == nil)
}

private func release(tag: String, assets: [[String: Any]], prerelease: Bool = false, body: String? = "Fixes") -> Data {
    var obj: [String: Any] = ["tag_name": tag, "html_url": "https://github.com/sdruckerfig/claudemonitor/releases/tag/\(tag)",
                              "draft": false, "prerelease": prerelease, "assets": assets]
    if let body { obj["body"] = body }
    return try! JSONSerialization.data(withJSONObject: obj)
}

private func asset(_ name: String, url: String? = nil, size: Int = 1_043_563) -> [String: Any] {
    ["name": name, "size": size,
     "browser_download_url": url ?? "https://github.com/sdruckerfig/claudemonitor/releases/download/v0.1.5/\(name)"]
}

@Test func aNewerReleaseWithItsPackageIsOffered() throws {
    let data = release(tag: "v0.1.5", assets: [asset("notes.txt"), asset("Other.pkg"), asset("ClaudeMonitor-0.1.5.pkg")])
    guard case .success(.available(let u)) = UpdateCheck.parse(data, current: "0.1.4") else {
        Issue.record("expected an update")
        return
    }
    #expect(u.version == "0.1.5")
    #expect(u.packageName == "ClaudeMonitor-0.1.5.pkg")          // the expected name wins over other packages
    #expect(u.packageBytes == 1_043_563)
    #expect(u.pageURL.absoluteString.hasSuffix("/releases/tag/v0.1.5"))
    #expect(u.notes == "Fixes")
}

@Test func theSameOrAnOlderReleaseIsUpToDate() {
    let data = release(tag: "v0.1.4", assets: [asset("ClaudeMonitor-0.1.4.pkg")])
    #expect(UpdateCheck.parse(data, current: "0.1.4") == .success(.upToDate(latest: "0.1.4")))
    #expect(UpdateCheck.parse(data, current: "0.2.0") == .success(.upToDate(latest: "0.1.4")))
    let pre = release(tag: "v0.9.0", assets: [asset("ClaudeMonitor-0.9.0.pkg")], prerelease: true)
    #expect(UpdateCheck.parse(pre, current: "0.1.4") == .success(.upToDate(latest: "0.9.0")))
}

@Test func packagesHostedElsewhereOrMissingAreNotOffered() {
    let elsewhere = release(tag: "v0.1.5", assets: [asset("ClaudeMonitor-0.1.5.pkg", url: "https://example.com/ClaudeMonitor-0.1.5.pkg")])
    #expect(throws: UpdateCheck.Failure.self) { try UpdateCheck.parse(elsewhere, current: "0.1.4").get() }
    let otherRepo = release(tag: "v0.1.5", assets: [asset("ClaudeMonitor-0.1.5.pkg",
        url: "https://github.com/someone/claudemonitor/releases/download/v0.1.5/ClaudeMonitor-0.1.5.pkg")])
    #expect(throws: UpdateCheck.Failure.self) { try UpdateCheck.parse(otherRepo, current: "0.1.4").get() }
    let none = release(tag: "v0.1.5", assets: [])
    #expect(throws: UpdateCheck.Failure.self) { try UpdateCheck.parse(none, current: "0.1.4").get() }
    #expect(throws: UpdateCheck.Failure.self) { try UpdateCheck.parse(Data("{}".utf8), current: "0.1.4").get() }
}

@Test func gatekeeperVerdictsAreParsedAndJudged() {
    let ok = PackageVerifier.parse("""
        /Users/x/Library/Caches/io.github.sdruckerfig.claudemonitor/Updates/ClaudeMonitor-0.1.5.pkg: accepted
        source=Notarized Developer ID
        origin=Developer ID Installer: Steve DRUCKER (CK6W3N87NQ)
        """, status: 0)
    #expect(ok.accepted && ok.notarized)
    #expect(ok.teamId == "CK6W3N87NQ")
    #expect(PackageVerifier.problem(with: ok, expectedTeam: "CK6W3N87NQ") == nil)
    #expect(PackageVerifier.problem(with: ok, expectedTeam: nil) == nil)               // built from source
    #expect(PackageVerifier.problem(with: ok, expectedTeam: "ZZZZZZZZZZ")?.contains("not by this app's developer") == true)

    let unnotarized = PackageVerifier.parse("x.pkg: accepted\nsource=Developer ID\norigin=Developer ID Installer: A (CK6W3N87NQ)", status: 0)
    #expect(PackageVerifier.problem(with: unnotarized, expectedTeam: "CK6W3N87NQ")?.contains("isn't notarized") == true)

    let rejected = PackageVerifier.parse("x.pkg: rejected\nsource=no usable signature", status: 3)
    #expect(!rejected.accepted)
    #expect(PackageVerifier.problem(with: rejected, expectedTeam: nil)?.contains("rejected") == true)
    // "accepted" in the text means nothing if spctl failed.
    #expect(!PackageVerifier.parse("x.pkg: accepted\nsource=Notarized Developer ID", status: 1).accepted)
}
