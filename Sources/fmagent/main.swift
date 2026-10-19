// fmagent: chat with Apple's on-device model, which can run shell commands.
import Foundation
import FoundationModels
import FMAgentCore

let autoApprove = CommandLine.arguments.contains("--yes")

func approved(_ question: String) -> Bool {
    if autoApprove { return true }
    print("\(question) [y/N] ", terminator: "")
    return readLine()?.lowercased().hasPrefix("y") == true
}

let instructions = """
    You are a terminal assistant on macOS. When the user asks about their system, files, or wants something done, \
    use the runCommand tool to run shell commands instead of guessing, then answer from the real output. \
    Prefer one simple command at a time. To create or edit a file, always use the writeFile tool with the full content. \
    Only claim something worked if the tool result confirms it. Current directory: \(FileManager.default.currentDirectoryPath)
    """

// macOS 27 renamed the error; check both so the tool also runs on macOS 26.
func isContextFull(_ error: Error) -> Bool {
    if #available(macOS 27, *), case LanguageModelError.contextSizeExceeded = error { return true }
    if case LanguageModelSession.GenerationError.exceededContextWindowSize = error { return true }
    return false
}

func newSession() -> LanguageModelSession {
    LanguageModelSession(tools: [RunCommand(approve: approved), WriteFile(approve: approved)], instructions: instructions)
}

guard case .available = SystemLanguageModel.default.availability else {
    print("Apple Foundation Model unavailable: \(SystemLanguageModel.default.availability)")
    exit(1)
}

var session = newSession()
print("fmagent — on-device model with shell access\(autoApprove ? " (auto-approve ON)" : ""). Ctrl-D to quit, /reset to clear.")
while true {
    print("\n\u{1B}[36m> \u{1B}[0m", terminator: "")
    guard let line = readLine() else { break }
    let prompt = line.trimmingCharacters(in: .whitespaces)
    if prompt.isEmpty { continue }
    if prompt == "/reset" { session = newSession(); print("Session cleared."); continue }
    do {
        print(try await session.respond(to: prompt).content)
    } catch where isContextFull(error) {
        session = newSession()
        print("Context window full; session was reset. Please repeat your request.")
    } catch {
        print("Error: \(error)")
    }
}
