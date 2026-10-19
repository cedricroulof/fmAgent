// fmagent: chat with Apple's on-device model, which can run shell commands.
import Foundation
import FoundationModels
import FMAgentCore

let autoApprove = CommandLine.arguments.contains("--yes")

// libedit gives arrow-key editing, history and Tab filename completion; fall back to readLine when piped.
// \u{1}...\u{2} mark the color codes as zero-width so the cursor position stays right.
// shortcut: declared directly because a C module target breaks Swift Testing's macros with the Command Line Tools
// toolchain; switch to a systemLibrary target once that's fixed.
@_silgen_name("readline") func readline(_ prompt: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("add_history") @discardableResult func add_history(_ line: UnsafePointer<CChar>) -> Int32

func input(_ prompt: String) -> String? {
    guard isatty(0) != 0 else {
        print(prompt.filter { $0 != "\u{1}" && $0 != "\u{2}" }, terminator: "")
        return readLine()
    }
    guard let cLine = readline(prompt) else { return nil }
    defer { free(cLine) }
    return String(cString: cLine)
}

// `!command` runs on the user's terminal directly (interactive programs work) and is never sent to the model.
// posix_spawn, not Process: Process puts the child in its own process group, so it would miss Ctrl-C and
// interactive programs couldn't read the terminal.
func runDirect(_ command: String) {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGINT)
    sigaddset(&defaults, SIGQUIT)
    posix_spawnattr_setsigdefault(&attr, &defaults)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))

    // Like system(3): Ctrl-C stops the command, not fmagent
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)
    defer { signal(SIGINT, SIG_DFL); signal(SIGQUIT, SIG_DFL) }
    fflush(stdout)  // print our pending output before the command's

    let argv = ["/bin/zsh", "-c", command].map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let err = posix_spawn(&pid, "/bin/zsh", nil, &attr, argv, environ)
    guard err == 0 else { print("Error: \(String(cString: strerror(err)))"); return }

    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    let signaled = status & 0x7f
    let code = signaled == 0 ? (status >> 8) & 0xff : 128 + signaled
    if code != 0 { print("\u{1B}[2m(exit \(code))\u{1B}[0m") }
}

func approved(_ question: String) -> Bool {
    if autoApprove { return true }
    return input("\(question) [y/N] ")?.lowercased().hasPrefix("y") == true
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
    print()
    guard let line = input("\u{1}\u{1B}[36m\u{2}> \u{1}\u{1B}[0m\u{2}") else { break }
    let prompt = line.trimmingCharacters(in: .whitespaces)
    if prompt.isEmpty { continue }
    add_history(prompt)
    if prompt.hasPrefix("!") {
        runDirect(String(prompt.dropFirst()))
        continue
    }
    if prompt == "/reset" { session = newSession(); print("Session cleared."); continue }
    do {
        print(renderMarkdown(try await session.respond(to: prompt).content))
    } catch where isContextFull(error) {
        session = newSession()
        print("Context window full; session was reset. Please repeat your request.")
    } catch {
        print("Error: \(error)")
    }
}
