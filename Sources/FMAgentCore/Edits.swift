import Foundation

/// A change to one file, computed but not applied yet. `original` is the content it was computed from
/// (nil for a new file); applying it is refused if the file no longer matches, so a newer file is never overwritten.
public struct EditProposal: Sendable {
    public let path: String
    public let shown: String
    public let original: String?
    public let updated: String
    public var diff: String { unifiedDiff(old: original, new: updated, path: shown) }
}

/// Text copied from readFile output may keep its "12<tab>" line numbers; drop them when every line has one.
func withoutLineNumbers(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let numbered = /^ *\d+(\t|\| ?)/
    guard lines.allSatisfy({ $0.isEmpty || $0.firstMatch(of: numbered) != nil }) else { return text }
    return lines.map { $0.replacing(numbered, with: "", maxReplacements: 1) }.joined(separator: "\n")
}

/// Replace `oldText`, which must occur exactly once, with `newText`.
public func proposeReplacement(at path: String, shown: String, oldText: String, newText: String) -> Result<EditProposal, InspectionError> {
    var (oldText, newText) = (oldText, newText)
    if oldText != withoutLineNumbers(oldText) { (oldText, newText) = (withoutLineNumbers(oldText), withoutLineNumbers(newText)) }
    guard !oldText.isEmpty else { return .failure(.init("oldText is empty; copy the exact lines to change from readFile")) }
    let text: String
    switch loadText(path, shown: shown) {
    case .failure(let error): return .failure(error)
    case .success(let loaded) where loaded.partial: return .failure(.init("\(shown) is too large to edit"))
    case .success(let loaded): text = loaded.text
    }
    let matches = text.ranges(of: oldText)
    if matches.isEmpty {
        return .failure(.init("oldText was not found in \(shown); nothing changed. Copy it exactly from the readFile result, spaces included, without the line numbers"))
    }
    if matches.count > 1 {
        return .failure(.init("oldText occurs \(matches.count) times in \(shown); nothing changed. Include more surrounding lines so it matches once"))
    }
    guard oldText != newText else { return .failure(.init("oldText and newText are the same; nothing to change")) }
    return .success(EditProposal(path: path, shown: shown, original: text, updated: text.replacingCharacters(in: matches[0], with: newText)))
}

/// Create a file, or overwrite an existing text file (shown as a diff against what is there now).
public func proposeWrite(at path: String, shown: String, content: String) -> Result<EditProposal, InspectionError> {
    guard FileManager.default.fileExists(atPath: path) else {
        return .success(EditProposal(path: path, shown: shown, original: nil, updated: content))
    }
    switch loadText(path, shown: shown) {
    case .failure: return .failure(.init("\(shown) exists and is not a text file; not overwritten"))
    case .success(let loaded) where loaded.partial: return .failure(.init("\(shown) is too large to overwrite"))
    case .success(let loaded): return .success(EditProposal(path: path, shown: shown, original: loaded.text, updated: content))
    }
}

/// Writes the proposal if the file still holds what it was computed from. Atomic, keeps the file's permissions.
public func apply(_ edit: EditProposal) -> Result<Void, InspectionError> {
    let exists = FileManager.default.fileExists(atPath: edit.path)
    if let original = edit.original {
        guard exists, (try? String(contentsOfFile: edit.path, encoding: .utf8)) == original else {
            return .failure(.init("\(edit.shown) changed since the preview; nothing was written. Read it again"))
        }
    } else if exists {
        return .failure(.init("\(edit.shown) was created since the preview; nothing was written. Read it first"))
    }
    do {
        let permissions = try? FileManager.default.attributesOfItem(atPath: edit.path)[.posixPermissions]
        try FileManager.default.createDirectory(atPath: (edit.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try edit.updated.write(toFile: edit.path, atomically: true, encoding: .utf8)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: edit.path) }
        return .success(())
    } catch {
        return .failure(.init("Failed to write \(edit.shown): \(error.localizedDescription)"))
    }
}

func lines(_ text: String) -> [Substring] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if text.hasSuffix("\n") || text.isEmpty { lines.removeLast() }
    return lines
}

/// A unified diff with one hunk spanning the changed lines (edits here change one contiguous region).
public func unifiedDiff(old: String?, new: String, path: String, context: Int = 3) -> String {
    let a = lines(old ?? ""), b = lines(new)
    var prefix = 0
    while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix && suffix < b.count - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
    if prefix == a.count && prefix == b.count { return "(no line changes)" }

    let start = max(0, prefix - context)
    let endA = min(a.count, a.count - suffix + context), endB = min(b.count, b.count - suffix + context)
    func range(_ start: Int, _ end: Int) -> String { "\(end > start ? start + 1 : start),\(end - start)" }
    var out = [old == nil ? "--- /dev/null" : "--- a/\(path)", "+++ b/\(path)", "@@ -\(range(start, endA)) +\(range(start, endB)) @@"]
    out += a[start..<prefix].map { " " + $0 }
    out += a[prefix..<(a.count - suffix)].map { "-" + $0 }
    out += b[prefix..<(b.count - suffix)].map { "+" + $0 }
    out += a[(a.count - suffix)..<endA].map { " " + $0 }
    return out.joined(separator: "\n")
}

/// The diff for the terminal: colored, and cut after `maxLines`.
public func coloredDiff(_ diff: String, maxLines: Int = 80) -> String {
    let all = diff.split(separator: "\n", omittingEmptySubsequences: false)
    var shown = all.prefix(maxLines).map { line -> String in
        switch line.first {
        case "+" where !line.hasPrefix("+++"): "\u{1B}[32m\(line)\u{1B}[0m"
        case "-" where !line.hasPrefix("---"): "\u{1B}[31m\(line)\u{1B}[0m"
        case "@": "\u{1B}[36m\(line)\u{1B}[0m"
        default: "\u{1B}[2m\(line)\u{1B}[0m"
        }
    }
    if all.count > maxLines { shown.append("\u{1B}[2m… \(all.count - maxLines) more diff lines\u{1B}[0m") }
    return shown.joined(separator: "\n")
}

/// Edits applied in this session, newest last, so `/undo` can revert the latest one.
public final class EditJournal: @unchecked Sendable {
    struct Entry { let path: String, shown: String, before: String?, after: String }
    private let lock = NSLock()
    private var entries: [Entry] = []

    public init() {}

    public func record(_ edit: EditProposal) {
        lock.withLock { entries.append(Entry(path: edit.path, shown: edit.shown, before: edit.original, after: edit.updated)) }
    }

    /// Reverts the latest edit if the file is still exactly as fmagent left it; otherwise changes nothing.
    /// Returns what happened, for the user, and whether something was undone.
    public func undoLatest() -> (message: String, undone: Bool) {
        lock.withLock {
            guard let entry = entries.last else { return ("Nothing to undo.", false) }
            guard (try? String(contentsOfFile: entry.path, encoding: .utf8)) == entry.after else {
                return ("\(entry.shown) changed after fmagent edited it; not undone, so your changes are kept.", false)
            }
            do {
                if let before = entry.before {
                    let permissions = try? FileManager.default.attributesOfItem(atPath: entry.path)[.posixPermissions]
                    try before.write(toFile: entry.path, atomically: true, encoding: .utf8)
                    if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: entry.path) }
                } else {
                    try FileManager.default.removeItem(atPath: entry.path)
                }
            } catch {
                return ("Couldn't undo the edit to \(entry.shown): \(error.localizedDescription)", false)
            }
            entries.removeLast()
            return (entry.before == nil ? "Removed \(entry.shown), which fmagent had created." : "Restored \(entry.shown) to before fmagent's edit.", true)
        }
    }
}
