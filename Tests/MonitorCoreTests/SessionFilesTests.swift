import Foundation
import Testing
@testable import MonitorCore

@Test func parsesRealSessionFileShape() throws {
    let json = """
    {"pid":17557,"sessionId":"abc","cwd":"/Users/x/code/notes-app","startedAt":1795107268119,
     "kind":"interactive","name":"notes-app-b6","status":"waiting","waitingFor":"dialog open",
     "updatedAt":1795107987483,"statusUpdatedAt":1795107987000}
    """
    let r = try #require(SessionFiles.parse(Data(json.utf8)))
    #expect(r.pid == 17557)
    #expect(r.sessionId == "abc")
    #expect(r.name == "notes-app-b6")
    #expect(r.status == .waiting)
    #expect(r.waitingFor == "dialog open")
    #expect(r.statusUpdatedAt == Date(timeIntervalSince1970: 1_795_107_987))
}

@Test func toleratesMissingAndUnknownFields() throws {
    let r = try #require(SessionFiles.parse(Data(#"{"pid":5,"cwd":"/Users/x/proj","status":"compacting"}"#.utf8)))
    #expect(r.name == "proj")
    #expect(r.status == .other("compacting"))
    #expect(r.status.label == "compacting")
    #expect(r.statusUpdatedAt == nil)
    #expect(SessionFiles.parse(Data(#"{"name":"no pid"}"#.utf8)) == nil)
    #expect(SessionFiles.parse(Data("not json".utf8)) == nil)
}

@Test func loadsOnlyJsonFilesFromDirectory() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(#"{"pid":1,"name":"a"}"#.utf8).write(to: dir.appendingPathComponent("1.json"))
    try Data("secret".utf8).write(to: dir.appendingPathComponent("1.abc.key"))
    try Data("{".utf8).write(to: dir.appendingPathComponent("2.json"))
    #expect(SessionFiles.load(from: dir).map(\.name) == ["a"])
}

@Test func formatting() {
    #expect(Format.bytes(Int64(5) * 1_073_741_824) == "5.0 GB")
    #expect(Format.bytes(Int64(300) * 1_048_576) == "300 MB")
    #expect(Format.cores(9.12) == "9.1 cores")
    #expect(Format.cores(0.01) == "0 cores")
    #expect(Format.duration(30) == "30s")
    #expect(Format.duration(37 * 60) == "37m")
    #expect(Format.duration(5 * 3600 + 10) == "5h")
    #expect(Format.duration(3 * 86400) == "3d")
    #expect(Format.path("/Users/x/code/a", home: "/Users/x") == "~/code/a")
    #expect(Format.path("/Users/xy", home: "/Users/x") == "/Users/xy")
}
