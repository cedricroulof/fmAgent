import CryptoKit
import Foundation

/// One request and its answer, as saved: the text the user typed (not attached file contents or shell output).
public struct Exchange: Codable, Equatable, Sendable {
    public var request: String
    public var answer: String

    public init(request: String, answer: String) {
        self.request = TaskLog.short(request, 1_000)
        self.answer = String(answer.prefix(2_000))
    }
}

/// A conversation saved to disk so it can be resumed. Versioned so older or newer files are skipped, not misread.
public struct SavedSession: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = SavedSession.currentVersion
    public var id: String
    public var title: String
    public var updated: Date
    public var workspace: String
    public var task: TaskLog.Snapshot
    public var exchanges: [Exchange]
    public var fileHashes: [String: String]  // file fmagent changed → SHA-256 of its content at save time

    public init(id: String, title: String, updated: Date = Date(), workspace: String, task: TaskLog.Snapshot,
                exchanges: [Exchange], fileHashes: [String: String]) {
        (self.id, self.title, self.updated, self.workspace) = (id, title, updated, workspace)
        (self.task, self.exchanges, self.fileHashes) = (task, Array(exchanges.suffix(20)), fileHashes)
    }

    /// Files fmagent changed that are different now (edited elsewhere, or deleted).
    public func filesChangedSince() -> [String] {
        fileHashes.filter { fileHash($0.key) != $0.value }.keys.sorted()
    }

    /// The part of a resumed session's instructions that recalls the conversation; nothing is rerun.
    public func recap() -> String {
        var lines = ["This conversation was resumed from a saved session. Nothing was rerun. The last exchanges:"]
        for exchange in exchanges.suffix(3) {
            lines.append("User: " + TaskLog.short(exchange.request, 300))
            lines.append("You (not verified): " + TaskLog.short(exchange.answer, 300))
        }
        let changed = filesChangedSince()
        if !changed.isEmpty {
            lines.append("These files changed since then; read them again before relying on them: "
                         + changed.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

/// SHA-256 of a file's content, nil if it can't be read.
public func fileHash(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
}

/// Saved sessions as private JSON files, one per session.
public struct SessionStore: Sendable {
    public let directory: String

    public init(directory: String = NSHomeDirectory() + "/.fmagent/sessions") { self.directory = directory }

    func file(_ id: String) -> String { directory + "/" + id + ".json" }

    public func save(_ session: SavedSession) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: URL(fileURLWithPath: file(session.id)), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(session.id))
    }

    /// Newest first; files from another version or that can't be read are skipped.
    public func list() -> [SavedSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { FileManager.default.contents(atPath: directory + "/" + $0) }
            .compactMap { try? decoder.decode(SavedSession.self, from: $0) }
            .filter { $0.version == SavedSession.currentVersion }
            .sorted { $0.updated > $1.updated }
    }

    public func delete(_ id: String) throws { try FileManager.default.removeItem(atPath: file(id)) }

    /// A new session id, sortable by time.
    public static func newID(_ date: Date = Date()) -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss"
        format.locale = Locale(identifier: "en_US_POSIX")
        return format.string(from: date) + "-" + UUID().uuidString.prefix(4).lowercased()
    }
}
