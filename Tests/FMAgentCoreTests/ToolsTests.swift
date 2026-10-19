import Foundation
import FoundationModels
import Testing
@testable import FMAgentCore

let yes: @Sendable (String) -> Bool = { _ in true }
let no: @Sendable (String) -> Bool = { _ in false }

func tempPath(_ name: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("fmagent-\(UUID().uuidString)-\(name)").path
}

@Test func runShellCapturesStdoutStderrAndStatus() {
    let (out, status) = runShell("echo out; echo err >&2; exit 3")
    #expect(out == "out\nerr\n")
    #expect(status == 3)
}

@Test func runShellDoesNotWaitForInput() {
    // stdin is /dev/null, so a command reading input ends immediately instead of hanging
    let (out, status) = runShell("cat")
    #expect(out == "")
    #expect(status == 0)
}

@Test func runShellHandlesLargeOutput() {
    // more than a pipe buffer (64 KB): would deadlock if the process were waited on before reading
    let (out, status) = runShell("head -c 200000 /dev/zero | tr '\\0' a")
    #expect(out.count == 200_000)
    #expect(status == 0)
}

@Test func truncatedKeepsShortOutput() {
    #expect(truncated("hello") == "hello")
    let exact = String(repeating: "x", count: maxOutput)
    #expect(truncated(exact) == exact)
}

@Test func truncatedKeepsTailOfLongOutput() {
    let long = String(repeating: "a", count: 10) + String(repeating: "b", count: maxOutput)
    #expect(truncated(long) == "[...truncated 10 chars...]\n" + String(repeating: "b", count: maxOutput))
}

@Test func runCommandReturnsExitCodeAndOutput() async throws {
    let result = try await RunCommand(approve: yes).call(arguments: GeneratedContent(properties: ["command": "echo hi"]))
    #expect(result == "exit code: 0\nhi\n")
}

@Test func runCommandDeclinedDoesNotRun() async throws {
    let path = tempPath("declined")
    let result = try await RunCommand(approve: no).call(arguments: GeneratedContent(properties: ["command": "touch '\(path)'"]))
    #expect(result == "The user declined to run this command.")
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func writeFileWritesMultilineContent() async throws {
    let path = tempPath("main.c")
    defer { try? FileManager.default.removeItem(atPath: path) }
    let code = "#include <stdio.h>\n\nint main() {\n    printf(\"Hello, world!\\n\");\n    return 0;\n}\n"
    let result = try await WriteFile(approve: yes).call(arguments: GeneratedContent(properties: ["path": path, "content": code]))
    #expect(result == "Wrote \(code.utf8.count) bytes to \(path).")
    #expect(try String(contentsOfFile: path, encoding: .utf8) == code)
}

@Test func writeFileDeclinedDoesNotWrite() async throws {
    let path = tempPath("declined.txt")
    let result = try await WriteFile(approve: no).call(arguments: GeneratedContent(properties: ["path": path, "content": "x"]))
    #expect(result == "The user declined to write this file.")
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func writeFileReportsFailure() async throws {
    let result = try await WriteFile(approve: yes).call(arguments: GeneratedContent(properties: ["path": "/nonexistent-dir/x.txt", "content": "x"]))
    #expect(result.hasPrefix("Failed to write /nonexistent-dir/x.txt"))
}

@Test func toolSchemasExposeExpectedArguments() {
    #expect(RunCommand(approve: yes).name == "runCommand")
    #expect(WriteFile(approve: yes).name == "writeFile")
    #expect(String(describing: RunCommand(approve: yes).parameters).contains("command"))
    let writeSchema = String(describing: WriteFile(approve: yes).parameters)
    #expect(writeSchema.contains("path") && writeSchema.contains("content"))
}

@Test func renderMarkdownStripsFencesAndColorsCode() {
    let md = "Run this:\n```bash\npython3 sort.py 23 1 2322\n```\nDone."
    #expect(renderMarkdown(md) == "Run this:\n  \u{1B}[32mpython3 sort.py 23 1 2322\u{1B}[39m\nDone.")
}

@Test func renderMarkdownDoesNotStyleInsideCodeBlocks() {
    #expect(renderMarkdown("```\n- **x** `y`\n```") == "  \u{1B}[32m- **x** `y`\u{1B}[39m")
}

@Test func renderMarkdownInlineStyles() {
    #expect(renderMarkdown("a **b** `c`") == "a \u{1B}[1mb\u{1B}[22m \u{1B}[36mc\u{1B}[39m")
    #expect(renderMarkdown("2 * 3 * 4") == "2 * 3 * 4")
}

@Test func renderMarkdownHeadersAndBullets() {
    #expect(renderMarkdown("## Files") == "\u{1B}[1;4mFiles\u{1B}[0m")
    #expect(renderMarkdown("- one\n  * two") == "• one\n  • two")
}

func visible(_ s: String) -> String { s.replacing(/\u{1B}\[[0-9;]*m/, with: "") }

@Test func appleFramesKeepTheirSizeWhileSpinning() {
    for step in 0..<24 {
        let lines = AppleLogo.frame(angle: Double(step) * .pi / 12)
        #expect(lines.count == AppleLogo.height)
        #expect(lines.allSatisfy { visible($0).count == AppleLogo.width })
    }
}

@Test func appleFacingAwayIsMirrored() {
    let front = AppleLogo.pixelGrid(angle: 0)
    #expect(front == AppleLogo.pixels)
    #expect(AppleLogo.pixelGrid(angle: .pi) == front.map { Array($0.reversed()) })
}

@Test func pathCompletionsListsDirectoriesFirstAndMatchesPrefix() throws {
    let dir = tempPath("completion")
    let fm = FileManager.default
    try fm.createDirectory(atPath: dir + "/Sources/fmagent", withIntermediateDirectories: true)
    for file in ["README.md", ".gitignore", "Sources/main.swift"] { fm.createFile(atPath: dir + "/" + file, contents: nil) }
    defer { try? fm.removeItem(atPath: dir) }

    #expect(pathCompletions(for: "", in: dir) == ["Sources/", ".gitignore", "README.md"])
    #expect(pathCompletions(for: "re", in: dir) == ["README.md"])
    #expect(pathCompletions(for: "Sources/", in: dir) == ["Sources/fmagent/", "Sources/main.swift"])
    #expect(pathCompletions(for: "Sources/ma", in: dir) == ["Sources/main.swift"])
    #expect(pathCompletions(for: "missing/", in: dir) == [])
    #expect(pathCompletions(for: dir + "/RE", in: "/") == [dir + "/README.md"])
}
