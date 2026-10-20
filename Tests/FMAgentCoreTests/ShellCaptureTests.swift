import Foundation
import Testing
@testable import FMAgentCore

@Test func terminalRecordingsBecomePlainText() {
    let raw = "^D\u{08}\u{08}\u{1B}[31merror:\u{1B}[0m build failed\r\n\u{1B}]0;title\u{07}Compiling 10%\rCompiling 100%\r\nab\u{08}c\r\n\r\n"
    #expect(cleanTerminalOutput(Data(raw.utf8)) == "error: build failed\nCompiling 100%\nac")
    #expect(cleanTerminalOutput(Data("\u{1B}[?1049hvim screen\u{1B}[?1049l".utf8)) == nil)
    let long = (1...2_000).map { "line \($0)" }.joined(separator: "\r\n")
    let cut = cleanTerminalOutput(Data(long.utf8), limit: 100)!
    #expect(cut.hasPrefix("[… start not shown …]\n") && cut.hasSuffix("line 2000") && cut.count < 130)
}

@Test func shellRecordsBecomeRequestsForTheModel() {
    let record = ShellRecord(command: "swift test", folder: "app", exitCode: 1, output: "error: x")
    let explain = record.request(fix: false)
    #expect(explain.contains("$ swift test\nExit code: 1\n"))
    #expect(explain.contains("```\nerror: x\n```"))
    #expect(explain.hasSuffix("Explain briefly what happened and why."))
    #expect(record.request(fix: true).contains("apply the smallest fix with replaceText"))
    #expect(ShellRecord(command: "vim a", folder: "app", exitCode: 0, output: nil).request(fix: false).contains("(not captured: it was a full-screen program)"))
}
