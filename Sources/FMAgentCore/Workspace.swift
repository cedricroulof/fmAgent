import Foundation

/// The directory the assistant works in. Tools, completion and attachments all resolve paths through it, so
/// relative paths, `~`, spaces and Unicode behave the same everywhere (no shell is involved).
public final class Workspace: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String

    public init(root: String = FileManager.default.currentDirectoryPath) {
        current = (root as NSString).standardizingPath
    }

    public var root: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = (newValue as NSString).standardizingPath } }
    }

    public func resolve(_ path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        // the model often starts paths with the workspace's own name ("myproj/src"): unless such a subfolder
        // exists, that name means the workspace itself
        let root = root, name = (root as NSString).lastPathComponent
        if expanded == name || expanded.hasPrefix(name + "/"), !FileManager.default.fileExists(atPath: root + "/" + name) {
            expanded = "." + expanded.dropFirst(name.count)
        }
        let absolute = expanded.hasPrefix("/") ? expanded : root + "/" + expanded
        return (absolute as NSString).standardizingPath
    }

    /// `/cd <path>`: moves the workspace to an existing folder (home when `path` is empty).
    /// Returns the new folder for display, with `~` for the home folder.
    public func change(to path: String) -> Result<String, InspectionError> {
        let target = path.isEmpty ? NSHomeDirectory() : resolve(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir) else { return .failure(.init("No such folder: \(path)")) }
        guard isDir.boolValue else { return .failure(.init("\(path) is a file, not a folder")) }
        guard FileManager.default.isReadableFile(atPath: target) else { return .failure(.init("Can't open \(path): permission denied")) }
        root = target
        return .success(Workspace.tilde(target))
    }

    /// A path with the home folder written `~`.
    public static func tilde(_ path: String) -> String {
        path == NSHomeDirectory() || path.hasPrefix(NSHomeDirectory() + "/") ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }

    /// How to show a resolved path: relative to the workspace when inside it.
    public func display(_ absolute: String) -> String {
        let base = root.hasSuffix("/") ? root : root + "/"
        return absolute.hasPrefix(base) ? String(absolute.dropFirst(base.count)) : absolute
    }
}

/// Whether a `!` command is just `cd [path]`. Anything more (`cd x && make`, `cd x` then `pwd` on the next line)
/// goes to zsh as written.
public func isStandaloneCd(_ command: String) -> Bool {
    (command == "cd" || command.hasPrefix("cd ")) && command.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>`$()\n\r")) == nil
}

/// What every tool needs from the app: where paths resolve, how to ask the user, a hook run before output, and
/// where applied edits are recorded.
public struct ToolContext: Sendable {
    public var workspace: Workspace
    public var approve: @Sendable (String) -> Bool
    public var willRun: @Sendable () -> Void  // called before the tool prints anything
    public var journal: EditJournal  // applied edits, for /undo
    public var commandTimeout: TimeInterval  // seconds before a model command is stopped
    public var isCancelled: @Sendable () -> Bool  // the user asked to stop (Ctrl-C)
    public var log: TaskLog  // what happened, to continue after a context reset

    public init(workspace: Workspace = Workspace(), approve: @escaping @Sendable (String) -> Bool,
                willRun: @escaping @Sendable () -> Void = {}, journal: EditJournal = EditJournal(),
                commandTimeout: TimeInterval = 60, isCancelled: @escaping @Sendable () -> Bool = { false },
                log: TaskLog = TaskLog()) {
        self.workspace = workspace
        self.log = log
        self.journal = journal
        self.commandTimeout = commandTimeout
        self.isCancelled = isCancelled
        self.approve = approve
        self.willRun = willRun
    }
}
