import Foundation
import Testing
@testable import MonitorCore

/// The README screenshot is rendered from DemoData; keep it showing what the README describes.
@Test func demoDataShowsEachKindOfState() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let s = DemoData.snapshot(now: now, home: "/Users/demo")
    #expect(s.rollup == .yellow)
    #expect(s.reasons.count == 1)
    let claude = s.sessions(of: .claude)
    #expect(claude.map(\.usage.record.name) == ["Fix flaky login test", "Checkout redesign", "API rate limiting", "Docs cleanup"])
    #expect(claude.map(\.level) == [.yellow, .yellow, .green, .green])
    #expect(claude.last?.isStale == true)
    let codex = s.sessions(of: .codex)
    #expect(codex.map(\.usage.record.name) == ["Migrate the feature store"])
    #expect(codex.first?.usage.record.subagentCount == 1)
    #expect(codex.first?.usage.descendants.map(\.pid).sorted() == [4510, 4511])   // its subagent's tests, not the app server
    #expect(s.leftovers.map(\.name) == ["next :3000", "http.server :8000"])
    #expect(s.leftovers.map(\.members.count) == [2, 1])
    #expect(s.services.map(\.name) == ["vite :5173", "postgres :5432", "Gradle daemon"])
    #expect(s.services.map(\.ownerText) == ["session “Checkout redesign”", "session “API rate limiting”", "running on its own"])
    #expect(s.otherGroups.map(\.name) == ["Safari", "Docker", "Simulators", "Mail"])

    let scan = DemoData.worktreeScan(now: now, home: "/Users/demo")
    #expect(scan.reclaimable.count == 3)
    #expect(scan.reclaimable.allSatisfy { $0.path.hasPrefix("/Users/demo/code/") })
}
