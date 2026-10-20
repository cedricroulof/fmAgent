import Foundation
import FoundationModels
import Testing
@testable import FMAgentCore

func contents(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

@Test func replacementChangesExactlyOneOccurrence() throws {
    let dir = try makeTree("replace", ["a.swift": "let x = 1\nlet y = 2\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let edit = try proposeReplacement(at: dir + "/a.swift", shown: "a.swift", oldText: "let y = 2", newText: "let y = 3").get()
    #expect(edit.diff == "--- a/a.swift\n+++ b/a.swift\n@@ -1,2 +1,2 @@\n let x = 1\n-let y = 2\n+let y = 3")
    #expect(throws: Never.self) { try apply(edit).get() }
    #expect(contents(dir + "/a.swift") == "let x = 1\nlet y = 3\n")
}

@Test func missingAmbiguousAndEmptyReplacementsChangeNothing() throws {
    let dir = try makeTree("ambiguous", ["a.txt": "same\nsame\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    func error(_ old: String, _ new: String = "x") -> String? {
        if case .failure(let e) = proposeReplacement(at: dir + "/a.txt", shown: "a.txt", oldText: old, newText: new) { return e.message }
        return nil
    }
    #expect(error("same") == "oldText occurs 2 times in a.txt; nothing changed. Include more surrounding lines so it matches once")
    #expect(error("other")?.hasPrefix("oldText was not found in a.txt; nothing changed.") == true)
    #expect(error("")?.hasPrefix("oldText is empty") == true)
    #expect(error("same\nsame", "same\nsame") == "oldText and newText are the same; nothing to change")
    #expect(contents(dir + "/a.txt") == "same\nsame\n")
}

@Test func stalePreviewIsNotApplied() throws {
    let dir = try makeTree("stale", ["a.txt": "v1\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let edit = try proposeReplacement(at: dir + "/a.txt", shown: "a.txt", oldText: "v1", newText: "v2").get()
    try "user edit\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)  // changed after the preview
    if case .failure(let e) = apply(edit) { #expect(e.message == "a.txt changed since the preview; nothing was written. Read it again") }
    else { Issue.record("stale edit was applied") }
    #expect(contents(dir + "/a.txt") == "user edit\n")

    let create = try proposeWrite(at: dir + "/new.txt", shown: "new.txt", content: "mine").get()
    try "theirs".write(toFile: dir + "/new.txt", atomically: true, encoding: .utf8)
    #expect(throws: InspectionError.self) { try apply(create).get() }
    #expect(contents(dir + "/new.txt") == "theirs")
}

@Test func editsKeepPermissionsAndHandleUnicodePaths() throws {
    let dir = try makeTree("perms", ["dossier été/run me.sh": "#!/bin/sh\necho hi\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/dossier été/run me.sh"
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    try apply(try proposeReplacement(at: path, shown: "run me.sh", oldText: "hi", newText: "bye").get()).get()
    #expect(contents(path) == "#!/bin/sh\necho bye\n")
    #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
}

@Test func diffsForNewAndRewrittenFiles() {
    #expect(unifiedDiff(old: nil, new: "a\nb\n", path: "n.txt") == "--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+a\n+b")
    let old = (1...10).map(String.init).joined(separator: "\n") + "\n"
    let new = old.replacingOccurrences(of: "5\n", with: "five\n")
    #expect(unifiedDiff(old: old, new: new, path: "f") == "--- a/f\n+++ b/f\n@@ -2,7 +2,7 @@\n 2\n 3\n 4\n-5\n+five\n 6\n 7\n 8")
    #expect(unifiedDiff(old: "a\n", new: "a\n", path: "f") == "(no line changes)")
    #expect(visible(coloredDiff(String(repeating: "+x\n", count: 100), maxLines: 3)).hasSuffix("… 98 more diff lines"))
}

@Test func replaceToolAsksAndDeclinedEditsChangeNothing() async throws {
    let dir = try makeTree("tool", ["src/a.txt": "hello\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let args = GeneratedContent(properties: ["path": "src/a.txt", "oldText": "hello", "newText": "bye"])
    let declined = try await ReplaceText(ToolContext(workspace: Workspace(root: dir), approve: no)).call(arguments: args)
    #expect(declined.hasPrefix("The user declined this change; nothing was written."))
    #expect(contents(dir + "/src/a.txt") == "hello\n")
    let done = try await ReplaceText(ToolContext(workspace: Workspace(root: dir), approve: yes)).call(arguments: args)
    #expect(done == "Edited src/a.txt.")
    #expect(contents(dir + "/src/a.txt") == "bye\n")
}

@Test func writeToolShowsOverwritesAndRefusesBinaryFiles() async throws {
    let dir = try makeTree("write", ["a.txt": "old\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/img.bin", contents: Data([0, 1, 2]))
    let context = ToolContext(workspace: Workspace(root: dir), approve: yes)
    #expect(try await WriteFile(context).call(arguments: GeneratedContent(properties: ["path": "a.txt", "content": "new\n"])) == "Overwrote a.txt (4 bytes).")
    #expect(contents(dir + "/a.txt") == "new\n")
    let binary = try await WriteFile(context).call(arguments: GeneratedContent(properties: ["path": "img.bin", "content": "x"]))
    #expect(binary == "img.bin exists and is not a text file; not overwritten")
    #expect(FileManager.default.contents(atPath: dir + "/img.bin") == Data([0, 1, 2]))
}

@Test func lineNumbersCopiedFromReadFileAreIgnored() throws {
    let dir = try makeTree("numbers", ["calc.py": "def double(x):\n    return x * 2\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let edit = try proposeReplacement(at: dir + "/calc.py", shown: "calc.py", oldText: "2\t    return x * 2", newText: "2\t    return x * 3").get()
    #expect(edit.updated == "def double(x):\n    return x * 3\n")
    #expect(withoutLineNumbers("a | b") == "a | b")  // not every line numbered: kept as is
}
