// fmagent: chat with Apple's on-device model, which can run shell commands.
import Foundation
import FoundationModels
import FMAgentCore

let autoApprove = CommandLine.arguments.contains("--yes")

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
    let previousInt = signal(SIGINT, SIG_IGN)
    let previousQuit = signal(SIGQUIT, SIG_IGN)
    defer { signal(SIGINT, previousInt); signal(SIGQUIT, previousQuit) }
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
    print("\(question) [y/N] ", terminator: "")
    return readLine()?.lowercased().hasPrefix("y") == true
}

let instructions = """
    You are a terminal assistant on macOS. Answer questions, explanations and code examples directly in your reply \
    (Markdown is fine); never use a tool to print or echo text. Use the runCommand tool only when you need real \
    information from the user's system or must change it, then answer from its output. Prefer one simple command \
    at a time. To create or edit a file, use the writeFile tool with the full content. If the user declines a \
    command, do not retry it. Only claim something worked if the tool result confirms it. Current directory: \(FileManager.default.currentDirectoryPath)
    """

// macOS 27 renamed the error; check both so the tool also runs on macOS 26.
func isContextFull(_ error: Error) -> Bool {
    if #available(macOS 27, *), case LanguageModelError.contextSizeExceeded = error { return true }
    if case LanguageModelSession.GenerationError.exceededContextWindowSize = error { return true }
    return false
}

// Before a tool prints: stop background drawing, and settle the welcome apple since tool output could scroll it.
let stopAnimations: @Sendable () -> Void = {
    runningSpinner.stop()
    welcomeApple.settle()
}

func newSession() -> LanguageModelSession {
    LanguageModelSession(tools: [RunCommand(approve: approved, willRun: stopAnimations), WriteFile(approve: approved, willRun: stopAnimations)], instructions: instructions)
}

guard case .available = SystemLanguageModel.default.availability else {
    print("Apple Foundation Model unavailable: \(SystemLanguageModel.default.availability)")
    exit(1)
}

let tui: TerminalUI? = isatty(0) != 0 && isatty(1) != 0 ? TerminalUI(autoApprove: autoApprove) : nil
var session = newSession()
if let tui { tui.start() } else { print("fmagent — on-device model with shell access. Ctrl-D to quit, /clear to reset.") }

while true {
    var line: String
    var shell = false
    if let tui {
        guard let input = tui.read() else { break }
        (line, shell) = input
    } else {
        print("> ", terminator: "")
        guard let input = readLine() else { break }
        line = input
        if line.hasPrefix("!") { shell = true; line.removeFirst() }
    }
    let prompt = line.trimmingCharacters(in: .whitespaces)
    if prompt.isEmpty { continue }
    if shell { runDirect(prompt); continue }
    if prompt == "/clear" || prompt == "/reset" {
        session = newSession()
        if let tui { tui.clearScreen() } else { print("Session cleared.") }
        continue
    }

    tui?.startWorking()
    var reply: String
    do {
        reply = "● " + renderMarkdown(try await session.respond(to: stripFileMentions(prompt)).content).replacingOccurrences(of: "\n", with: "\n  ")
    } catch where isContextFull(error) {
        session = newSession()
        reply = "Context window full; session was reset. Please repeat your request."
    } catch {
        reply = "Error: \(error)"
    }
    tui?.stopWorking()
    print("\n" + reply)
}
tui?.finish()
