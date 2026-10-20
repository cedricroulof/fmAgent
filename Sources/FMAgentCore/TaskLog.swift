import Foundation

/// What happened in the current task, recorded by fmagent from tool results (not from what the model says),
/// so a fresh session can continue after the model's context fills up.
public final class TaskLog: @unchecked Sendable {
    private let lock = NSLock()
    private var goal: String?
    private var filesChanged: [String] = []
    private var lastCommand: String?
    private var events: [String] = []
    private var lastRequest: String?
    private var lastAnswer: String?
    private var changes = 0  // commands run and files written, to know if a request had side effects

    public init() {}

    static func short(_ text: String, _ limit: Int = 200) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : flat.prefix(limit) + "…"
    }

    private func event(_ text: String) {
        events.append(TaskLog.short(text, 120))
        if events.count > 6 { events.removeFirst() }
    }

    public func request(_ text: String) {
        lock.withLock {
            if goal == nil { goal = TaskLog.short(text) }
            lastRequest = TaskLog.short(text)
        }
    }

    public func answer(_ text: String) { lock.withLock { lastAnswer = TaskLog.short(text, 300) } }

    public func commandRan(_ command: String, _ summary: String) {
        lock.withLock {
            lastCommand = TaskLog.short("\(command) -> \(summary)")
            event("ran `\(command)`: \(summary)")
            changes += 1
        }
    }

    public func fileChanged(_ path: String) {
        lock.withLock {
            filesChanged.removeAll { $0 == path }
            filesChanged.append(path)
            event("changed \(path)")
            changes += 1
        }
    }

    public func declined(_ what: String) { lock.withLock { event("the user declined: \(what)") } }
    public func note(_ what: String) { lock.withLock { event(what) } }

    /// Grows with every command run or file written.
    public var changeCount: Int { lock.withLock { changes } }

    public func clear() {
        lock.withLock { (goal, filesChanged, lastCommand, events, lastRequest, lastAnswer) = (nil, [], nil, [], nil, nil) }
    }

    /// A compact record for a fresh session's instructions; nil when nothing happened yet.
    public func summary(workspace: String) -> String? {
        lock.withLock {
            guard let goal else { return nil }
            // the folder name only: the small model mangles long absolute paths it copies
            var lines = ["Goal: \(goal)", "Workspace: the current folder, \((workspace as NSString).lastPathComponent) (use relative paths)"]
            if !filesChanged.isEmpty { lines.append("Files changed: " + filesChanged.suffix(10).joined(separator: ", ")) }
            if let lastCommand { lines.append("Last command: \(lastCommand)") }
            if !events.isEmpty { lines.append("Recent events: " + events.joined(separator: "; ")) }
            if let lastRequest { lines.append("Last request: \(lastRequest)") }
            if let lastAnswer { lines.append("Your last answer (your own words, not verified): \(lastAnswer)") }
            return lines.joined(separator: "\n")
        }
    }
}
