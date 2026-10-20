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
    let result = try await RunCommand(ToolContext(approve: yes)).call(arguments: GeneratedContent(properties: ["command": "echo hi"]))
    #expect(result == "exit code: 0\nhi\n")
}

@Test func runCommandDeclinedDoesNotRun() async throws {
    let path = tempPath("declined")
    let result = try await RunCommand(ToolContext(approve: no)).call(arguments: GeneratedContent(properties: ["command": "touch '\(path)'"]))
    #expect(result == "The user declined to run this command. Do not run it again; answer without it.")
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func writeFileWritesMultilineContent() async throws {
    let path = tempPath("main.c")
    defer { try? FileManager.default.removeItem(atPath: path) }
    let code = "#include <stdio.h>\n\nint main() {\n    printf(\"Hello, world!\\n\");\n    return 0;\n}\n"
    let result = try await WriteFile(ToolContext(approve: yes)).call(arguments: GeneratedContent(properties: ["path": path, "content": code]))
    #expect(result == "Wrote \(code.utf8.count) bytes to \(path).")
    #expect(try String(contentsOfFile: path, encoding: .utf8) == code)
}

@Test func writeFileDeclinedDoesNotWrite() async throws {
    let path = tempPath("declined.txt")
    let result = try await WriteFile(ToolContext(approve: no)).call(arguments: GeneratedContent(properties: ["path": path, "content": "x"]))
    #expect(result == "The user declined to write this file. Do not write it again; answer without it.")
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func writeFileReportsFailure() async throws {
    let result = try await WriteFile(ToolContext(approve: yes)).call(arguments: GeneratedContent(properties: ["path": "/nonexistent-dir/x.txt", "content": "x"]))
    #expect(result.hasPrefix("Failed to write /nonexistent-dir/x.txt"))
}

@Test func toolSchemasExposeExpectedArguments() {
    #expect(RunCommand(ToolContext(approve: yes)).name == "runCommand")
    #expect(WriteFile(ToolContext(approve: yes)).name == "writeFile")
    #expect(String(describing: RunCommand(ToolContext(approve: yes)).parameters).contains("command"))
    let writeSchema = String(describing: WriteFile(ToolContext(approve: yes)).parameters)
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

@Test func appleChangesAsItTurns() {
    #expect(AppleLogo.frame(angle: 0) != AppleLogo.frame(angle: .pi / 2))
    #expect(visible(AppleLogo.frame(angle: 0).joined()).filter { $0 != " " }.count > 200)  // the apple is drawn
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

@Test func toolsCallWillRunBeforeWorking() async throws {
    final class Flag: @unchecked Sendable { var called = false }
    let flag = Flag()
    _ = try await RunCommand(ToolContext(approve: no, willRun: { flag.called = true })).call(arguments: GeneratedContent(properties: ["command": "true"]))
    #expect(flag.called)
}

@Test func writeFileCreatesMissingDirectories() async throws {
    let dir = tempPath("project")
    defer { try? FileManager.default.removeItem(atPath: dir) }
    _ = try await WriteFile(ToolContext(approve: yes)).call(arguments: GeneratedContent(properties: ["path": dir + "/src/main.rs", "content": "fn main() {}\n"]))
    #expect(try String(contentsOfFile: dir + "/src/main.rs", encoding: .utf8) == "fn main() {}\n")
}

@Test func fileMentionsReachTheModelAsPlainPaths() {
    #expect(stripFileMentions("explain @src/main.rs and @README.md") == "explain src/main.rs and README.md")
    #expect(stripFileMentions("@Package.swift") == "Package.swift")
    #expect(stripFileMentions("mail me at a@b.com, @ alone") == "mail me at a@b.com, @ alone")
}

@Test func cursorReportKeepsTypeahead() {
    let report = Array("\u{1B}[12;5R".utf8)
    #expect(extractCursorReport(from: report).map { [$0.row, $0.col] } == [12, 5])
    // keys typed before and after the report, including an arrow key and an uppercase R, survive
    let mixed = Array("hi R\u{1B}[A".utf8) + report + Array("x".utf8)
    let found = extractCursorReport(from: mixed)
    #expect(found.map { [$0.row, $0.col] } == [12, 5])
    #expect(found?.rest == Array("hi R\u{1B}[Ax".utf8))
    #expect(extractCursorReport(from: Array("\u{1B}[12;".utf8)) == nil)  // incomplete
    #expect(extractCursorReport(from: Array("abc".utf8)) == nil)
}

@Test func multiLinePastesBecomePlaceholders() {
    var pastes = PasteStore()
    #expect(pastes.insert("one line") == "one line")
    let code = "fn main() {\r    println!(\"hi\");\r}\r"  // terminals send pasted newlines as \\r
    let placeholder = pastes.insert(code)
    #expect(placeholder == "[Pasted text #1 +3 lines]")
    #expect(pastes.insert("a\nb") == "[Pasted text #2 +2 lines]")
    #expect(pastes.expand("explain \(placeholder) please") == "explain fn main() {\n    println!(\"hi\");\n}\n please")
    #expect(pastes.placeholder(endingAt: "explain \(placeholder)") == placeholder)
    #expect(pastes.placeholder(endingAt: "explain") == nil)
}
