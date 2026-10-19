// Renders the Markdown the model replies with as terminal text: code blocks, headers, bullets, **bold**, `code`.
public func renderMarkdown(_ text: String) -> String {
    var inCode = false
    var lines: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            inCode.toggle()
            continue
        }
        if inCode {
            lines.append("  \u{1B}[32m\(line)\u{1B}[39m")
        } else if let header = trimmed.firstMatch(of: /^#{1,6}\s+(.*)/) {
            lines.append("\u{1B}[1;4m\(inline(String(header.1)))\u{1B}[0m")
        } else if let item = line.firstMatch(of: /^(\s*)[-*+]\s+(.*)/) {
            lines.append("\(item.1)• \(inline(String(item.2)))")
        } else {
            lines.append(inline(String(line)))
        }
    }
    return lines.joined(separator: "\n")
}

func inline(_ s: String) -> String {
    s.replacing(/`([^`]+)`/) { "\u{1B}[36m\($0.1)\u{1B}[39m" }
        .replacing(/\*\*(.+?)\*\*/) { "\u{1B}[1m\($0.1)\u{1B}[22m" }
}
