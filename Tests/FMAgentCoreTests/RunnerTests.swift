import Foundation
import Testing
@testable import FMAgentCore

/// A killed process can linger briefly as a zombie until it is reaped, so give it up to 2 s to disappear.
func isAlive(_ pid: pid_t) -> Bool {
    for _ in 0..<40 {
        if kill(pid, 0) != 0 { return false }
        usleep(50_000)
    }
    return true
}

func pid(in file: String) -> pid_t? {
    for _ in 0..<50 {  // the command writes it right away; give it a moment
        if let text = try? String(contentsOfFile: file, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
        usleep(20_000)
    }
    return nil
}

@Test func runnerCapturesOutputAndExitCode() {
    let result = runCommand("echo out; echo err >&2; exit 3")
    #expect(result.outcome == .exited(3))
    #expect(result.output == "out\nerr\n")
    #expect(result.summary == "exit code: 3")
}

@Test func runnerNeverWaitsForTheKeyboardAndRunsInTheGivenFolder() {
    #expect(runCommand("cat").outcome == .exited(0))
    let dir = tempPath("cwd")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    #expect(runCommand("pwd -P", in: dir).output.hasSuffix((dir as NSString).lastPathComponent + "\n"))
    #expect(runCommand("yes | head -2").output == "y\ny\n")  // SIGPIPE works in the child
}

@Test func runnerKeepsOnlyTheStartAndEndOfHugeOutput() {
    let result = runCommand("awk 'BEGIN { for (i = 1; i <= 2000000; i++) print i }'", headBytes: 100, tailBytes: 200)
    let expected = (1...2_000_000).reduce(0) { $0 + String($1).utf8.count + 1 }  // what awk prints, ~15 MB
    #expect(result.outcome == .exited(0))
    #expect(result.totalBytes == expected)
    #expect(result.output.hasPrefix("1\n2\n3\n"))
    #expect(result.output.hasSuffix("1999999\n2000000\n"))
    #expect(result.output.contains("[… \(expected - 300) bytes not shown …]"))
    #expect(result.output.utf8.count < 400)
}

@Test func timeoutStopsTheCommandAndItsChildren() {
    let file = tempPath("child.pid")
    defer { try? FileManager.default.removeItem(atPath: file) }
    let start = Date()
    let result = runCommand("sleep 300 & echo $! > '\(file)'; wait", timeout: 0.5)
    #expect(result.outcome == .timedOut(0.5))
    #expect(Date().timeIntervalSince(start) < 5)
    let child = pid(in: file)
    #expect(child != nil)
    if let child { #expect(!isAlive(child)) }
}

@Test func backgroundLeftoversOfAFinishedCommandAreStopped() {
    let file = tempPath("leftover.pid")
    defer { try? FileManager.default.removeItem(atPath: file) }
    let start = Date()
    let result = runCommand("sleep 300 & echo $! > '\(file)'; echo started")
    #expect(result.outcome == .exited(0))
    #expect(result.output == "started\n")
    #expect(Date().timeIntervalSince(start) < 3)  // doesn't wait for the background sleep
    if let child = pid(in: file) { #expect(!isAlive(child)) } else { Issue.record("no pid written") }
}

@Test func closingTheOutputDoesNotEndTheCommand() {
    #expect(runCommand("exec 1>/dev/null 2>&1; sleep 5", timeout: 0.5).outcome == .timedOut(0.5))
    let start = Date()
    #expect(runCommand("echo hi; exec 1>&- 2>&-; sleep 0.5; exit 4").outcome == .exited(4))
    #expect(Date().timeIntervalSince(start) >= 0.5)
}

@Test func cancellationStopsTheCommand() {
    let start = Date()
    let result = runCommand("sleep 300", isCancelled: { Date().timeIntervalSince(start) > 0.3 })
    #expect(result.outcome == .cancelled)
    #expect(Date().timeIntervalSince(start) < 5)
    #expect(result.summary == "cancelled by the user; the command and its child processes were stopped")
}

@Test func runnerReportsSignalsAndStartFailures() {
    #expect(runCommand("kill -9 $$").outcome == .signaled(9))
    #expect(runCommand("true", in: "/nonexistent-folder").outcome != .exited(0))
}
