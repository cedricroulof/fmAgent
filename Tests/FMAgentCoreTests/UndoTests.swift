import Foundation
import FoundationModels
import Testing
@testable import FMAgentCore

@Test func undoRestoresTheLatestEditFirst() async throws {
    let dir = try makeTree("undo", ["a.txt": "one\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let journal = EditJournal()
    let context = ToolContext(workspace: Workspace(root: dir), approve: yes, journal: journal)
    _ = try await ReplaceText(context).call(arguments: GeneratedContent(properties: ["path": "a.txt", "oldText": "one", "newText": "two"]))
    _ = try await ReplaceText(context).call(arguments: GeneratedContent(properties: ["path": "a.txt", "oldText": "two", "newText": "three"]))
    #expect(journal.undoLatest() == ("Restored a.txt to before fmagent's edit.", true))
    #expect(contents(dir + "/a.txt") == "two\n")
    #expect(journal.undoLatest().undone)
    #expect(contents(dir + "/a.txt") == "one\n")
    #expect(journal.undoLatest() == ("Nothing to undo.", false))
}

@Test func undoRemovesCreatedFilesAndKeepsPermissions() async throws {
    let dir = try makeTree("undo-create", ["run.sh": "echo a\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/run.sh")
    let journal = EditJournal()
    let context = ToolContext(workspace: Workspace(root: dir), approve: yes, journal: journal)
    _ = try await ReplaceText(context).call(arguments: GeneratedContent(properties: ["path": "run.sh", "oldText": "a", "newText": "b"]))
    _ = try await WriteFile(context).call(arguments: GeneratedContent(properties: ["path": "new/n.txt", "content": "hi"]))
    #expect(journal.undoLatest() == ("Removed new/n.txt, which fmagent had created.", true))
    #expect(!FileManager.default.fileExists(atPath: dir + "/new/n.txt"))
    #expect(journal.undoLatest().undone)
    #expect(contents(dir + "/run.sh") == "echo a\n")
    #expect((try FileManager.default.attributesOfItem(atPath: dir + "/run.sh")[.posixPermissions] as? NSNumber)?.intValue == 0o755)
}

@Test func undoRefusesToOverwriteLaterUserChanges() async throws {
    let dir = try makeTree("undo-conflict", ["a.txt": "one\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let journal = EditJournal()
    let context = ToolContext(workspace: Workspace(root: dir), approve: yes, journal: journal)
    _ = try await ReplaceText(context).call(arguments: GeneratedContent(properties: ["path": "a.txt", "oldText": "one", "newText": "two"]))
    try "two, then the user's own change\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    #expect(journal.undoLatest() == ("a.txt changed after fmagent edited it; not undone, so your changes are kept.", false))
    #expect(contents(dir + "/a.txt") == "two, then the user's own change\n")
}

@Test func declinedEditsAreNotRecorded() async throws {
    let dir = try makeTree("undo-declined", ["a.txt": "one\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let journal = EditJournal()
    _ = try await ReplaceText(ToolContext(workspace: Workspace(root: dir), approve: no, journal: journal))
        .call(arguments: GeneratedContent(properties: ["path": "a.txt", "oldText": "one", "newText": "two"]))
    #expect(journal.undoLatest() == ("Nothing to undo.", false))
}
