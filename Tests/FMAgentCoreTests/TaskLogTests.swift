import Foundation
import FoundationModels
import Testing
@testable import FMAgentCore

@Test func taskLogRecordsVerifiedEventsCompactly() {
    let log = TaskLog()
    #expect(log.summary(workspace: "/p") == nil)
    log.request("fix the failing parser test")
    log.commandRan("swift test", "exit code: 1")
    log.fileChanged("Sources/Parser.swift")
    log.declined("run `rm -rf .build`")
    log.request("now run the tests again")
    log.answer("I changed the parser.\nTests should pass now.")
    #expect(log.summary(workspace: "/p") == """
        Goal: fix the failing parser test
        Workspace: the current folder, p (use relative paths)
        Files changed: Sources/Parser.swift
        Last command: swift test -> exit code: 1
        Recent events: ran `swift test`: exit code: 1; changed Sources/Parser.swift; the user declined: run `rm -rf .build`
        Last request: now run the tests again
        Your last answer (your own words, not verified): I changed the parser. Tests should pass now.
        """)
    #expect(log.changeCount == 2)  // the command and the file change, not the declined one
    #expect(log.declineCount == 1)
    log.clear()
    #expect(log.summary(workspace: "/p") == nil)
}

@Test func taskLogStaysBounded() {
    let log = TaskLog()
    log.request(String(repeating: "a", count: 1_000))
    for i in 1...50 { log.fileChanged("f\(i).txt") }
    let summary = log.summary(workspace: "/p")!
    #expect(summary.contains("Goal: " + String(repeating: "a", count: 200) + "…"))
    #expect(summary.contains("Files changed: f41.txt, f42.txt"))  // the last 10
    #expect(!summary.contains("f40.txt,"))
    #expect(summary.utf8.count < 1_200)
}

@Test func toolsRecordWhatTheyDid() async throws {
    let dir = try makeTree("log", ["a.txt": "one\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let log = TaskLog()
    log.request("edit a.txt")
    let context = ToolContext(workspace: Workspace(root: dir), approve: yes, log: log)
    _ = try await ReplaceText(context).call(arguments: GeneratedContent(properties: ["path": "a.txt", "oldText": "one", "newText": "two"]))
    _ = try await RunCommand(context).call(arguments: GeneratedContent(properties: ["command": "exit 4"]))
    _ = try await RunCommand(ToolContext(approve: no, log: log)).call(arguments: GeneratedContent(properties: ["command": "rm x"]))
    let summary = log.summary(workspace: dir)!
    #expect(summary.contains("Files changed: a.txt"))
    #expect(summary.contains("Last command: exit 4 -> exit code: 4"))
    #expect(summary.contains("the user declined: run `rm x`"))
}

@Test func changeRequestsAreToldFromQuestions() {
    for request in ["fix the bug in lib/calc.py", "lib/calc.py prints -1 instead of 5, can you fix it?", "Add a docstring to calc.py",
                    "make a folder named \"3DTree\" with a tree in it"] {
        #expect(asksForChange(request), "\(request)")
    }
    for request in ["what does lib/calc.py do?", "how do I fix this error?", "explain the fix", "is calc.py correct?", "yo"] {
        #expect(!asksForChange(request), "\(request)")
    }
}
