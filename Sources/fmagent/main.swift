// fmagent: chat with Apple's on-device model, which can run shell commands.
import Foundation
import FoundationModels
import FMAgentCore

let autoApprove = CommandLine.arguments.contains("--yes")
// --timeout <seconds>: how long a command run by the model may take
let commandTimeout = CommandLine.arguments.firstIndex(of: "--timeout").flatMap { index in
    CommandLine.arguments.dropFirst(index + 1).first.flatMap(TimeInterval.init)
} ?? 60
let workspace = Workspace()
let journal = EditJournal()
var notesForModel: [String] = []  // things that happened outside the model's view, told with the next prompt
// Terminal.app's session restore prints "Restored session…" around every interactive zsh started for `!` commands
setenv("SHELL_SESSIONS_DISABLE", "1", 1)

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

    // -i loads ~/.zshrc so the user's aliases and functions work; +m turns off job control, which would move the
    // command to its own process group and break Ctrl-C handling here
    let argv = ["/bin/zsh", "-i", "+m", "-c", command].map { strdup($0) } + [nil]
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

/// The model request in progress, so Ctrl-C can cancel it: the first press cancels, a second one quits.
final class RequestCanceller: @unchecked Sendable {
    enum Interrupt { case idle, cancelled, again }
    private let lock = NSLock()
    private var task: Task<String, Error>?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func begin(_ task: Task<String, Error>) { lock.withLock { (self.task, cancelled) = (task, false) } }
    func end() { lock.withLock { (task, cancelled) = (nil, false) } }

    func interrupt() -> Interrupt {
        lock.withLock {
            guard let task else { return .idle }
            if cancelled { return .again }
            cancelled = true
            task.cancel()
            return .cancelled
        }
    }
}

let canceller = RequestCanceller()

// Ctrl-C is handled here instead of killing fmagent: it cancels the model's request, or does nothing when idle
// (a `!` command gets it directly; the line editor reads it as a key).
signal(SIGINT, SIG_IGN)
let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue(label: "fmagent.interrupt"))
interrupts.setEventHandler(handler: onInterrupt)  // not a closure: one written here would be main-actor isolated and trap off the main thread
interrupts.resume()

@Sendable func onInterrupt() {
    switch canceller.interrupt() {
    case .idle: break
    case .cancelled:
        runningSpinner.stop()
        welcomeApple.settle()
        writeOut("\n\u{1B}[33mCancelling… (Ctrl-C again to quit)\u{1B}[0m\n")
    case .again:
        restoreTerminal()
        exit(130)
    }
}

func approved(_ question: String) -> Bool {
    if autoApprove { return true }
    print("\(question) [y/N] ", terminator: "")
    guard isatty(STDIN_FILENO) != 0 else { return readLine()?.lowercased().hasPrefix("y") == true }
    fflush(stdout)
    let answer = readApprovalKey(isCancelled: { canceller.isCancelled })
    print(answer == true ? "y" : "n")
    if answer == nil { onInterrupt() }  // Ctrl-C at the question: raw mode delivers it as a key
    return answer == true
}

let instructions = """
    You are a terminal assistant on macOS. Answer questions, explanations and code examples directly in your reply \
    (Markdown is fine); never use a tool to print or echo text. Use the runCommand tool only when you need real \
    information from the user's system or must change it, then answer from its output. Prefer one simple command \
    at a time. To look at files use readFile, listDirectory and searchFiles, not cat, ls or grep. To change part \
    of a file, read it, then use replaceText with the exact current text; use writeFile only for new files or full \
    rewrites. If the user declines a \
    command, do not retry it. Only claim something worked if the tool result confirms it. You work in the folder \(workspace.root); give paths relative to it, like calc.py or src/main.swift
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

/// Prefixes the prompt with what the model should know happened since its last answer (e.g. an undone edit).
@MainActor func withNotes(_ prompt: String) -> String {
    defer { notesForModel.removeAll() }
    return notesForModel.isEmpty ? prompt : "(" + notesForModel.joined(separator: " ") + ")\n" + prompt
}

func newSession() -> LanguageModelSession {
    let context = ToolContext(workspace: workspace, approve: approved, willRun: stopAnimations, journal: journal,
                              commandTimeout: commandTimeout, isCancelled: { canceller.isCancelled })
    let tools: [any Tool] = [RunCommand(context), WriteFile(context), ReplaceText(context), ReadFile(context), ListDirectory(context), SearchFiles(context)]
    return LanguageModelSession(tools: tools, instructions: instructions)
}

guard case .available = SystemLanguageModel.default.availability else {
    print("Apple Foundation Model unavailable: \(SystemLanguageModel.default.availability)")
    exit(1)
}

let tui: TerminalUI? = isatty(0) != 0 && isatty(1) != 0 ? TerminalUI(autoApprove: autoApprove, workspace: workspace) : nil
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
    if prompt == "/undo" {
        let (message, undone) = journal.undoLatest()
        print((undone ? "" : "\u{1B}[33m") + message + "\u{1B}[0m")
        if undone { notesForModel.append("The user ran /undo: " + message) }
        continue
    }
    if prompt == "/clear" || prompt == "/reset" {
        session = newSession()
        if let tui { tui.clearScreen() } else { print("Session cleared.") }
        continue
    }

    let (attached, attachmentNotes) = attachMentionedFiles(to: prompt, workspace: workspace)
    let message = withNotes(attached)
    for note in attachmentNotes { print("\u{1B}[2m  \(note)\u{1B}[0m") }
    tui?.startWorking()
    let request = Task { [session] in try await session.respond(to: message).content }
    canceller.begin(request)
    var reply: String
    do {
        reply = "● " + renderMarkdown(try await request.value).replacingOccurrences(of: "\n", with: "\n  ")
    } catch where canceller.isCancelled {
        reply = "\u{1B}[33mCancelled.\u{1B}[0m"
    } catch where isContextFull(error) {
        session = newSession()
        reply = "Context window full; session was reset. Please repeat your request."
    } catch {
        reply = "Error: \(error)"
    }
    canceller.end()
    tui?.stopWorking()
    print("\n" + reply)
}
tui?.finish()
