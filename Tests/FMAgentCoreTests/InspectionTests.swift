import Foundation
import FoundationModels
import Testing
@testable import FMAgentCore

func makeTree(_ name: String, _ files: [String: String]) throws -> String {
    let dir = tempPath(name)
    for (path, content) in files {
        let full = dir + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: full, atomically: true, encoding: .utf8)
    }
    return dir
}

@Test func workspaceResolvesRelativeTildeAndUnicodePaths() {
    let workspace = Workspace(root: "/tmp/projet été")
    #expect(workspace.resolve("src/main.swift") == "/tmp/projet été/src/main.swift")
    #expect(workspace.resolve("../x") == "/tmp/x")
    #expect(workspace.resolve("/etc/hosts") == "/etc/hosts")
    #expect(workspace.resolve("~/a") == NSHomeDirectory() + "/a")
    #expect(workspace.display("/tmp/projet été/src/a b.swift") == "src/a b.swift")
    #expect(workspace.display("/etc/hosts") == "/etc/hosts")
}

@Test func readFileReturnsNumberedRangeWithContinuation() throws {
    let dir = try makeTree("read", ["f.txt": (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    #expect(readFileExcerpt(dir + "/f.txt", shown: "f.txt", startLine: 3, lineCount: 2)
        == "f.txt, lines 3-4 of 10:\n3\tline 3\n4\tline 4\n[more: readFile startLine 5]")
    #expect(readFileExcerpt(dir + "/f.txt", shown: "f.txt", startLine: 9) == "f.txt, lines 9-10 of 10:\n9\tline 9\n10\tline 10")
    #expect(readFileExcerpt(dir + "/f.txt", shown: "f.txt", startLine: 11) == "f.txt has 10 lines; startLine 11 is past the end.")
}

@Test func readFileIsBoundedByBytesAndLineLength() throws {
    let long = String(repeating: "x", count: 5_000)
    let dir = try makeTree("bounds", ["long.txt": long + "\nshort\n", "many.txt": (1...500).map { "row \($0)" }.joined(separator: "\n")])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let one = readFileExcerpt(dir + "/long.txt", shown: "long.txt")
    #expect(one.contains("1\t" + String(repeating: "x", count: InspectionLimits.lineChars) + " … [+4600 chars]"))
    #expect(one.utf8.count < 1_000)
    let many = readFileExcerpt(dir + "/many.txt", shown: "many.txt", lineCount: 500)
    #expect(many.hasPrefix("many.txt, lines 1-120 of 500:"))
    #expect(many.hasSuffix("[more: readFile startLine 121]"))
    let tight = readFileExcerpt(dir + "/many.txt", shown: "many.txt", maxBytes: 100)
    #expect(tight.utf8.count < 200 && tight.contains("[more: readFile startLine"))
}

@Test func readFileExplainsWhatItCannotShow() throws {
    let dir = try makeTree("errors", ["empty.txt": ""])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/bin", contents: Data([0x00, 0x01, 0x02]))
    FileManager.default.createFile(atPath: dir + "/latin1", contents: Data([0x63, 0x61, 0x66, 0xE9]))
    #expect(readFileExcerpt(dir + "/missing", shown: "missing") == "No such file: missing")
    #expect(readFileExcerpt(dir, shown: "dir") == "dir is a directory; use listDirectory")
    #expect(readFileExcerpt(dir + "/bin", shown: "bin") == "bin looks like a binary file; not shown")
    #expect(readFileExcerpt(dir + "/latin1", shown: "latin1") == "latin1 is not UTF-8 text; not shown")
    #expect(readFileExcerpt(dir + "/empty.txt", shown: "empty.txt") == "empty.txt is empty.")
}

@Test func listDirectoryIsSortedAndBounded() throws {
    let dir = try makeTree("list", ["b.txt": "", "a/x.txt": "", "C.md": ""])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    #expect(listDirectory(dir, shown: "proj") == "proj (3 entries):\na/\nb.txt\nC.md")
    #expect(listDirectory(dir, shown: "proj", limit: 2) == "proj (3 entries):\na/\nb.txt\n[1 more not shown]")
    #expect(listDirectory(dir + "/b.txt", shown: "b.txt") == "b.txt is a file; use readFile")
}

@Test func searchFilesFindsLiteralTextAndSkipsNoise() throws {
    let dir = try makeTree("search", [
        "Sources/app.swift": "let total = 1\nfunc Total() {}\n",
        "Sources/b c/é.swift": "// total in a path with spaces\n",
        ".git/config": "total",
        "node_modules/x.js": "total",
    ])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/blob.bin", contents: Data("total".utf8) + Data([0]))
    let outside = try makeTree("outside", ["secret.txt": "total"])
    defer { try? FileManager.default.removeItem(atPath: outside) }
    try FileManager.default.createSymbolicLink(atPath: dir + "/linked", withDestinationPath: outside)  // not followed
    let workspace = Workspace(root: dir)
    let result = searchFiles("total", in: dir, display: workspace.display)
    #expect(result == "Sources/app.swift:1: let total = 1\nSources/app.swift:2: func Total() {}\nSources/b c/é.swift:1: // total in a path with spaces")
    #expect(searchFiles("total", in: dir, maxResults: 1).hasSuffix("[2 more matches not shown]"))
    #expect(searchFiles("total", in: dir, maxFiles: 1).contains("[stopped after scanning 1 files"))
    #expect(searchFiles("nothing", in: dir, shown: "proj") == "No matches for \"nothing\" in proj.")
    #expect(searchFiles("APP.sw", in: dir, display: workspace.display) == "Sources/app.swift: file name matches")
    #expect(searchFiles("total", in: dir + "/Sources/app.swift", display: workspace.display).hasPrefix("Sources/app.swift:1:"))
    let big = dir + "/big.txt"
    try String(repeating: "total\n", count: InspectionLimits.searchFileBytes / 6 + 1).write(toFile: big, atomically: true, encoding: .utf8)
    #expect(searchFiles("total", in: big, shown: "big.txt") == "big.txt is larger than 1 MB; not searched. Read it in parts with readFile.")
    #expect(searchFiles("x", in: "/dev/null", shown: "null") == "null is not a regular file; not searched.")
}

@Test func inspectionToolsResolvePathsInTheWorkspace() async throws {
    let dir = try makeTree("tools", ["notes/a b.txt": "hello\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let context = ToolContext(workspace: Workspace(root: dir), approve: no)
    let read = try await ReadFile(context).call(arguments: GeneratedContent(properties: ["path": "notes/a b.txt"]))
    #expect(read == "notes/a b.txt, lines 1-1 of 1:\n1\thello")
    let list = try await ListDirectory(context).call(arguments: GeneratedContent(properties: ["path": "notes"]))
    #expect(list == "notes (1 entries):\na b.txt")
    let found = try await SearchFiles(context).call(arguments: GeneratedContent(properties: ["query": "HELLO"]))
    #expect(found == "notes/a b.txt:1: hello")
}

@Test func changingTheWorkspaceMovesEveryPathResolution() throws {
    let dir = try makeTree("cd", ["sub dir/é.txt": "x", "file.txt": "y"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let workspace = Workspace(root: dir)
    #expect(try workspace.change(to: "sub dir").get().hasSuffix("/sub dir"))
    #expect(workspace.resolve("é.txt") == (dir as NSString).standardizingPath + "/sub dir/é.txt")
    #expect(listDirectory(workspace.resolve("."), shown: ".") == ". (1 entries):\né.txt")
    let here = (dir as NSString).standardizingPath + "/sub dir"
    #expect(workspace.resolve("sub dir") == here && workspace.resolve("sub dir/new/a.txt") == here + "/new/a.txt")
    #expect(workspace.resolve("sub dirx") == here + "/sub dirx")
    try FileManager.default.createDirectory(atPath: here + "/sub dir", withIntermediateDirectories: false)
    #expect(workspace.resolve("sub dir") == here + "/sub dir")  // a real subfolder of that name wins
    try FileManager.default.removeItem(atPath: here + "/sub dir")
    #expect(throws: InspectionError.self) { try workspace.change(to: "missing").get() }
    #expect(isStandaloneCd("cd") && isStandaloneCd("cd sub\\ dir") && isStandaloneCd("cd ~/x"))
    #expect(!isStandaloneCd("cd Sources\npwd") && !isStandaloneCd("cd x && make") && !isStandaloneCd("cd $HOME") && !isStandaloneCd("cdx"))
    #expect(throws: InspectionError.self) { try workspace.change(to: "../file.txt").get() }
    #expect(workspace.root.hasSuffix("/sub dir"))  // unchanged by the failed moves
    #expect(try workspace.change(to: "..").get() == Workspace.tilde((dir as NSString).standardizingPath))
    #expect(try workspace.change(to: "").get() == "~")
    #expect(Workspace.tilde(NSHomeDirectory() + "/code") == "~/code")
    #expect(Workspace.tilde("/tmp") == "/tmp")
}
