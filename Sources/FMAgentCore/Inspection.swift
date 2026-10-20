import Foundation

// Read-only file inspection with hard bounds, so results always fit the on-device model's small context.
public enum InspectionLimits {
    public static let readLines = 120  // default and maximum lines per readFile call
    public static let readBytes = 6_000  // a range stops early once this much text is collected
    public static let lineChars = 400  // longer lines are cut, so one huge line can't blow the budget
    public static let fileBytes = 8_000_000  // only this much of a file is loaded
    public static let listEntries = 100
    public static let searchResults = 30
    public static let searchFiles = 5_000
    public static let searchFileBytes = 1_000_000
    public static let searchLineChars = 200
}

/// Loads a file as text, or explains why it can't be shown.
func loadText(_ path: String, shown: String) -> Result<(text: String, partial: Bool), InspectionError> {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return .failure(.init("No such file: \(shown)")) }
    if isDir.boolValue { return .failure(.init("\(shown) is a directory; use listDirectory")) }
    guard let handle = FileHandle(forReadingAtPath: path) else { return .failure(.init("Can't open \(shown): permission denied")) }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: InspectionLimits.fileBytes + 1)) ?? Data()
    let partial = data.count > InspectionLimits.fileBytes
    let bytes = partial ? data.prefix(InspectionLimits.fileBytes) : data
    if bytes.prefix(8192).contains(0) { return .failure(.init("\(shown) looks like a binary file; not shown")) }
    guard let text = String(data: bytes, encoding: .utf8) ?? (partial ? String(decoding: bytes, as: UTF8.self) : nil) else {
        return .failure(.init("\(shown) is not UTF-8 text; not shown"))
    }
    return .success((text, partial))
}

public struct InspectionError: Error, Equatable {
    public let message: String
    init(_ message: String) { self.message = message }
}

func clip(_ line: Substring, to limit: Int) -> String {
    line.count <= limit ? String(line) : line.prefix(limit) + " … [+\(line.count - limit) chars]"
}

/// Numbered lines `startLine…` of a file, bounded by line count and bytes, with a hint to read further.
public func readFileExcerpt(_ path: String, shown: String? = nil, startLine: Int = 1,
                            lineCount: Int = InspectionLimits.readLines, maxBytes: Int = InspectionLimits.readBytes) -> String {
    let shown = shown ?? path
    let text: String, partial: Bool
    switch loadText(path, shown: shown) {
    case .failure(let error): return error.message
    case .success(let loaded): (text, partial) = loaded
    }
    if text.isEmpty { return "\(shown) is empty." }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if text.hasSuffix("\n") { lines.removeLast() }
    let total = lines.count
    let ofTotal = partial ? "at least \(total)" : "\(total)"
    let start = max(1, startLine)
    guard start <= total else { return "\(shown) has \(ofTotal) lines; startLine \(start) is past the end." }
    let wanted = min(max(1, lineCount), InspectionLimits.readLines)

    var body: [String] = [], bytes = 0, end = start - 1
    for number in start...min(total, start + wanted - 1) {
        let line = "\(number)| " + clip(lines[number - 1], to: InspectionLimits.lineChars)
        if bytes + line.utf8.count > maxBytes && !body.isEmpty { break }
        body.append(line)
        bytes += line.utf8.count + 1
        end = number
    }
    var result = "\(shown), lines \(start)-\(end) of \(ofTotal):\n" + body.joined(separator: "\n")
    if end < total { result += "\n[more: readFile startLine \(end + 1)]" }
    return result
}

/// Entries of a directory, folders first (with a trailing "/"), bounded.
public func listDirectory(_ path: String, shown: String? = nil, limit: Int = InspectionLimits.listEntries) -> String {
    let shown = shown ?? path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return "No such directory: \(shown)" }
    guard isDir.boolValue else { return "\(shown) is a file; use readFile" }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return "Can't list \(shown): permission denied" }
    let entries = names.map { name -> (String, Bool) in
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path + "/" + name, isDirectory: &isDir)
        return (name, isDir.boolValue)
    }
    .sorted { $0.1 != $1.1 ? $0.1 : $0.0.lowercased() < $1.0.lowercased() }
    .map { $0.0 + ($0.1 ? "/" : "") }
    if entries.isEmpty { return "\(shown) is empty." }
    var result = "\(shown) (\(entries.count) entries):\n" + entries.prefix(limit).joined(separator: "\n")
    if entries.count > limit { result += "\n[\(entries.count - limit) more not shown]" }
    return result
}

/// Case-insensitive literal search below `path` (or in one file). Hidden folders, dependency folders, symlinks,
/// binary and very large files are skipped; the number of files scanned and of results is bounded.
public func searchFiles(_ query: String, in path: String, shown: String? = nil, display: (String) -> String = { $0 },
                        maxResults: Int = InspectionLimits.searchResults, maxFiles: Int = InspectionLimits.searchFiles) -> String {
    let shown = shown ?? path
    guard !query.isEmpty else { return "The search text is empty." }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return "No such file or directory: \(shown)" }

    var files: [String] = []
    var stoppedEarly = false
    if isDir.boolValue {
        // walk by relative paths so results keep the folder as given (the system resolves /var → /private/var)
        let skipped: Set<String> = ["node_modules", "Pods", "DerivedData", "build", "dist", "target"]
        let walker = FileManager.default.enumerator(atPath: path)
        while let relative = walker?.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            let type = walker?.fileAttributes?[.type] as? FileAttributeType
            if name.hasPrefix(".") || (type == .typeDirectory && skipped.contains(name)) {
                if type == .typeDirectory { walker?.skipDescendants() }
                continue
            }
            let size = (walker?.fileAttributes?[.size] as? NSNumber)?.intValue ?? 0
            guard type == .typeRegular, size <= InspectionLimits.searchFileBytes else { continue }  // symlinks are skipped
            if files.count == maxFiles { stoppedEarly = true; break }
            files.append(path + "/" + relative)
        }
    } else {
        // the same checks as in the walk: a huge file would be read whole, and a FIFO or device would block
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return "\(shown) is not a regular file; not searched." }
        guard (values?.fileSize ?? 0) <= InspectionLimits.searchFileBytes else {
            return "\(shown) is larger than \(InspectionLimits.searchFileBytes / 1_000_000) MB; not searched. Read it in parts with readFile."
        }
        files = [path]
    }

    var matches: [String] = [], extra = 0
    for file in files.sorted() {
        guard let data = FileManager.default.contents(atPath: file), !data.prefix(8192).contains(0),
              let text = String(data: data, encoding: .utf8) else { continue }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.range(of: query, options: .caseInsensitive) != nil {
            if matches.count < maxResults {
                let content = clip(line.drop { $0 == " " || $0 == "\t" }, to: InspectionLimits.searchLineChars)
                matches.append("\(display(file)):\(index + 1): \(content)")
            } else {
                extra += 1
            }
        }
    }
    if matches.isEmpty { return "No matches for \"\(query)\" in \(shown)\(stoppedEarly ? " (stopped after \(maxFiles) files)" : "")." }
    var result = matches.joined(separator: "\n")
    if extra > 0 { result += "\n[\(extra) more matches not shown]" }
    if stoppedEarly { result += "\n[stopped after scanning \(maxFiles) files; search a smaller folder]" }
    return result
}
