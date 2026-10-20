/// Multi-line pastes are shown in the input box as a short placeholder ("[Pasted text #1 +17 lines]")
/// and replaced by the real text when the line is sent.
public struct PasteStore {
    var texts: [String: String] = [:]
    var count = 0

    public init() {}

    /// What to put in the input box: a single line as is, anything longer as a placeholder.
    public mutating func insert(_ pasted: String) -> String {
        let text = pasted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard text.contains("\n") else { return text }
        count += 1
        let lines = (text.hasSuffix("\n") ? text.dropLast() : Substring(text)).split(separator: "\n", omittingEmptySubsequences: false).count
        let placeholder = "[Pasted text #\(count) +\(lines) lines]"
        texts[placeholder] = text
        return placeholder
    }

    public func expand(_ line: String) -> String {
        texts.reduce(line) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    /// The placeholder right before the cursor, so Backspace can delete it whole.
    public func placeholder(endingAt prefix: String) -> String? {
        texts.keys.first { prefix.hasSuffix($0) }
    }
}
