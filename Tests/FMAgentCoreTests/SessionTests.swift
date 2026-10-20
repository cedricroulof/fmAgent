import Foundation
import Testing
@testable import FMAgentCore

func sampleSession(id: String, updated: Date, workspace: String = "/p", hashes: [String: String] = [:]) -> SavedSession {
    let log = TaskLog()
    log.request("fix the parser")
    log.fileChanged("a.swift", at: "/p/a.swift")
    return SavedSession(id: id, title: "fix the parser", updated: updated, workspace: workspace, task: log.snapshot(),
                        exchanges: [Exchange(request: "fix the parser", answer: "Done.")], fileHashes: hashes)
}

@Test func sessionsAreSavedPrivatelyAndListedNewestFirst() throws {
    let store = SessionStore(directory: tempPath("sessions"))
    defer { try? FileManager.default.removeItem(atPath: store.directory) }
    #expect(store.list().isEmpty)
    let old = sampleSession(id: "a", updated: Date(timeIntervalSince1970: 1_000))
    let new = sampleSession(id: "b", updated: Date(timeIntervalSince1970: 2_000))
    try store.save(old)
    try store.save(new)
    #expect(store.list() == [new, old])
    #expect((try FileManager.default.attributesOfItem(atPath: store.directory + "/a.json")[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((try FileManager.default.attributesOfItem(atPath: store.directory)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    try store.delete("a")
    #expect(store.list() == [new])
}

@Test func otherVersionsAndBrokenFilesAreSkipped() throws {
    let store = SessionStore(directory: tempPath("sessions-versions"))
    defer { try? FileManager.default.removeItem(atPath: store.directory) }
    var future = sampleSession(id: "future", updated: Date())
    future.version = 99
    try store.save(future)
    try "{ not json".write(toFile: store.directory + "/broken.json", atomically: true, encoding: .utf8)
    try store.save(sampleSession(id: "ok", updated: Date()))
    #expect(store.list().map(\.id) == ["ok"])
}

@Test func taskSnapshotsRoundTrip() {
    let log = TaskLog()
    log.request("goal")
    log.commandRan("swift test", "exit code: 1")
    log.fileChanged("x.swift", at: "/p/x.swift")
    let restored = TaskLog()
    restored.restore(log.snapshot())
    #expect(restored.summary(workspace: "/p") == log.summary(workspace: "/p"))
    #expect(restored.snapshot().changedFiles == ["/p/x.swift"])
}

@Test func resumingNoticesFilesChangedSinceTheSave() throws {
    let dir = try makeTree("resume", ["a.txt": "saved\n", "b.txt": "kept\n"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let session = sampleSession(id: "r", updated: Date(), hashes: [
        dir + "/a.txt": fileHash(dir + "/a.txt")!, dir + "/b.txt": fileHash(dir + "/b.txt")!, dir + "/gone.txt": "x",
    ])
    try "edited elsewhere\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    #expect(session.filesChangedSince() == [dir + "/a.txt", dir + "/gone.txt"])
    let recap = session.recap()
    #expect(recap.hasPrefix("This conversation was resumed from a saved session. Nothing was rerun."))
    #expect(recap.contains("User: fix the parser\nYou (not verified): Done."))
    #expect(recap.hasSuffix("read them again before relying on them: a.txt, gone.txt"))
}

@Test func savedExchangesAreBounded() {
    let many = (1...30).map { Exchange(request: "q\($0)" + String(repeating: "x", count: 5_000), answer: String(repeating: "a", count: 5_000)) }
    let session = SavedSession(id: "x", title: "t", workspace: "/p", task: TaskLog().snapshot(), exchanges: many, fileHashes: [:])
    #expect(session.exchanges.count == 20)
    #expect(session.exchanges.first!.request.hasPrefix("q11"))
    #expect(session.exchanges.allSatisfy { $0.request.count <= 1_001 && $0.answer.count == 2_000 })
}
