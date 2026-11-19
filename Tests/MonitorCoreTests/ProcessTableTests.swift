import Foundation
import Testing
@testable import MonitorCore

@Test func parsesElapsedFormats() {
    #expect(ProcessTable.parseElapsed("00:05") == 5)
    #expect(ProcessTable.parseElapsed("12:34") == 754)
    #expect(ProcessTable.parseElapsed("01:00:00") == 3600)
    #expect(ProcessTable.parseElapsed("06-23:07:41") == 6 * 86400 + 23 * 3600 + 7 * 60 + 41)
    #expect(ProcessTable.parseElapsed("garbage") == nil)
    #expect(ProcessTable.parseElapsed("1:2:3:4") == nil)
}

@Test func parsesMainRowsAndKeepsArgsWithSpaces() {
    let text = """
      401     1  68.3  102752 06-23:07:41 Ss   /System/Library/WindowServer -daemon
     9716  9599 423.2 3951280       01:20 R    /opt/homebrew/bin/csc /noconfig @/Users/x/my file.rsp
    not a process row
    """
    let rows = ProcessTable.parseMain(text)
    #expect(rows.count == 2)
    let csc = try! #require(rows[9716])
    #expect(csc.ppid == 9599)
    #expect(csc.cpuPercent == 423.2)
    #expect(csc.cores > 4.2 && csc.cores < 4.3)
    #expect(csc.rssKB == 3_951_280)
    #expect(csc.elapsedSeconds == 80)
    #expect(csc.state == "R")
    #expect(csc.args == "/opt/homebrew/bin/csc /noconfig @/Users/x/my file.rsp")
}

@Test func mergePrefersCommPathEvenWithSpaces() {
    let main = ProcessTable.parseMain("""
      5 1 2.0 1000 00:10 S /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --type=renderer
      6 1 0.0 1000 00:10 S /usr/bin/sleep 100
    """)
    let comm = ProcessTable.parseComm("""
      5 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
    """)
    let rows = ProcessTable.merge(main: main, comm: comm)
    #expect(rows.map(\.pid) == [5, 6])
    #expect(rows[0].name == "Google Chrome")
    #expect(rows[1].name == "sleep")   // not in comm output: falls back to first arg
}
