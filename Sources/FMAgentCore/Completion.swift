import Foundation

/// Directory entries matching a partly typed path ("Sources/fm" lists Sources/ entries starting with "fm"),
/// directories first with a trailing "/". Hidden files are included; matching ignores case.
public func pathCompletions(for partial: String, in cwd: String = FileManager.default.currentDirectoryPath) -> [String] {
    let slash = partial.lastIndex(of: "/")
    let dirPart = slash.map { String(partial[...$0]) } ?? ""
    let prefix = (slash.map { String(partial[partial.index(after: $0)...]) } ?? partial).lowercased()
    var dir = (dirPart as NSString).expandingTildeInPath
    if !dir.hasPrefix("/") { dir = cwd + "/" + dir }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    return names.filter { $0.lowercased().hasPrefix(prefix) }
        .map { name -> (String, Bool) in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: dir + "/" + name, isDirectory: &isDir)
            return (name, isDir.boolValue)
        }
        .sorted { $0.1 != $1.1 ? $0.1 : $0.0.lowercased() < $1.0.lowercased() }
        .map { dirPart + $0.0 + ($0.1 ? "/" : "") }
}

/// `@path` is how the user picks files in the input box; the model gets the plain path.
public func stripFileMentions(_ text: String) -> String {
    text.replacing(/(^|\s)@(?=\S)/) { $0.1 }
}
