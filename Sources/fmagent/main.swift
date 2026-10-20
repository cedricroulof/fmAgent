// fmagent: chat with Apple's on-device model, which can run shell commands.
import Foundation
import FoundationModels
import FMAgentCore

// shortcut: unguarded, but only /permissions writes it, between requests; use a lock if it ever changes mid-request
nonisolated(unsafe) var autoApprove = CommandLine.arguments.contains("--yes")
// --timeout <seconds>: how long a command run by the model may take
let commandTimeout = CommandLine.arguments.firstIndex(of: "--timeout").flatMap { index in
    CommandLine.arguments.dropFirst(index + 1).first.flatMap(TimeInterval.init)
} ?? 60
let workspace = Workspace()
let journal = EditJournal()
let taskLog = TaskLog()
// Conversations are saved after each answer (unless --no-save) so /resume can continue them later.
let saveSessions = !CommandLine.arguments.contains("--no-save")
let sessionStore = SessionStore()
var sessionID = SessionStore.newID()
var sessionTitle: String?
var exchanges: [Exchange] = []
// Set once shell output was shared (later answers can quote it) or the session was deleted; /clear and /resume reset it
var savingStopped = false
var resumeRecap: String?  // set by /resume for the next new session
var lastShell: ShellRecord?  // the latest !command, shared with the model only by /explain-last or /fix-last
var notesForModel: [String] = []  // things that happened outside the model's view, told with the next prompt
// Terminal.app's session restore prints "Restored session…" around every interactive zsh started for `!` commands
setenv("SHELL_SESSIONS_DISABLE", "1", 1)

// `!command` runs on the user's terminal directly (interactive programs work) and is never sent to the model.
// posix_spawn, not Process: Process puts the child in its own process group, so it would miss Ctrl-C and
// interactive programs couldn't read the terminal.
// It runs under script(1), which gives it a real terminal while recording the output to a private temporary file;
// the end of that output is kept in memory (never on disk) for /explain-last and /fix-last.
func runDirect(_ command: String) -> ShellRecord? {
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

    let log = NSTemporaryDirectory() + "fmagent-\(UUID().uuidString).log"
    FileManager.default.createFile(atPath: log, contents: nil, attributes: [.posixPermissions: 0o600])
    defer { try? FileManager.default.removeItem(atPath: log) }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    // piped input belongs to fmagent's next lines, not to the command
    if isatty(STDIN_FILENO) == 0 { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
    posix_spawn_file_actions_addchdir(&actions, workspace.root)  // the workspace, which /cd moves

    // -i loads ~/.zshrc so the user's aliases and functions work; +m turns off job control, which would move the
    // command to its own process group and break Ctrl-C handling here
    // "exit $?" keeps zsh from exec-ing the command itself: script(1) reports a signal-killed child as the bare
    // signal number (2 for Ctrl-C), while zsh reports 130
    let argv = ["/usr/bin/script", "-q", "-e", log, "/bin/zsh", "-i", "+m", "-c", command + "\nexit $?"].map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let err = posix_spawn(&pid, "/usr/bin/script", &actions, &attr, argv, environ)
    guard err == 0 else { print("Error: \(String(cString: strerror(err)))"); return nil }

    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    let signaled = status & 0x7f
    let code = signaled == 0 ? (status >> 8) & 0xff : 128 + signaled
    if code != 0 { print("\u{1B}[2m(exit \(code))\u{1B}[0m") }

    let handle = FileHandle(forReadingAtPath: log)
    defer { try? handle?.close() }
    let size = (try? handle?.seekToEnd()) ?? 0
    try? handle?.seek(toOffset: size > 65_536 ? size - 65_536 : 0)  // only the end matters
    let output = cleanTerminalOutput((try? handle?.readToEnd()) ?? Data())
    return ShellRecord(command: command, folder: (workspace.root as NSString).lastPathComponent, exitCode: code, output: output)
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
    command, do not retry it. Only claim something worked if the tool result confirms it. You work in the user's current folder, named \((workspace.root as NSString).lastPathComponent); give paths relative to it, like calc.py or src/main.swift (never an absolute path)
    """

// macOS 27 renamed the error; check both so the tool also runs on macOS 26.
func isContextFull(_ error: Error) -> Bool {
    if #available(macOS 27, *), case LanguageModelError.contextSizeExceeded = error { return true }
    if case LanguageModelSession.GenerationError.exceededContextWindowSize = error { return true }
    return mentionsTooManyTokens(error)
}

// shortcut: on macOS 27.0.1 an overflow during tool calls comes back as a private GenerativeError
// (.prompt(.tooManyTokens)) instead of LanguageModelError.contextSizeExceeded; matched by reflection until the
// SDK reports it with the public error.
func mentionsTooManyTokens(_ value: Any, depth: Int = 0) -> Bool {
    guard depth < 6 else { return false }
    return Mirror(reflecting: value).children.contains { $0.label == "tooManyTokens" || mentionsTooManyTokens($0.value, depth: depth + 1) }
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

@MainActor func newSession() -> LanguageModelSession {
    let context = ToolContext(workspace: workspace, approve: approved, willRun: stopAnimations, journal: journal,
                              commandTimeout: commandTimeout, isCancelled: { canceller.isCancelled }, log: taskLog)
    let tools: [any Tool] = [RunCommand(context), WriteFile(context), ReplaceText(context), ReadFile(context), ListDirectory(context), SearchFiles(context)]
    var text = instructions
    if let recap = resumeRecap { text += "\n\n" + recap }
    resumeRecap = nil
    if let record = taskLog.summary(workspace: workspace.root) {
        text += "\n\nWhat happened so far in this task, recorded by fmagent (do not redo what is listed as done):\n" + record
    }
    return LanguageModelSession(tools: tools, instructions: text)
}

/// Saves the conversation after an answer: typed requests and answers, the task record, the folder, and hashes of
/// the files fmagent changed (to notice later edits when resuming). Never shell output or attached file contents.
@MainActor func saveSession() {
    guard saveSessions, !savingStopped, let title = sessionTitle else { return }
    let task = taskLog.snapshot()
    let hashes = Dictionary(task.changedFiles.compactMap { path in fileHash(path).map { (path, $0) } }, uniquingKeysWith: { $1 })
    do {
        try sessionStore.save(SavedSession(id: sessionID, title: title, workspace: workspace.root, task: task,
                                           exchanges: exchanges, fileHashes: hashes))
    } catch {
        print("\u{1B}[33m  couldn't save this session: \(error.localizedDescription)\u{1B}[0m")
    }
}

func sessionLine(_ number: Int, _ saved: SavedSession) -> String {
    let date = DateFormatter()
    date.dateFormat = "MMM d HH:mm"
    let folder = (saved.workspace as NSString).lastPathComponent
    return "  \(number). \(date.string(from: saved.updated))  \(folder)  \(TaskLog.short(saved.title, 60))  (\(saved.exchanges.count) exchanges)"
}

enum Outcome { case answer(String), cancelled, failed(Error) }

/// Sends one message to the model; Ctrl-C cancels it (see RequestCanceller).
@MainActor func send(_ message: String) async -> Outcome {
    let request = Task { [session] in try await session.respond(to: message).content }
    canceller.begin(request)
    defer { canceller.end() }
    do { return .answer(try await request.value) } catch { return canceller.isCancelled ? .cancelled : .failed(error) }
}

/// Restarts the session from the task record before the conversation fills the model's context.
@MainActor func compactIfNeeded() async {
    guard #available(macOS 26.4, *) else { return }
    let model = SystemLanguageModel.default
    guard let used = try? await model.tokenCount(for: session.transcript), used > model.contextSize * 7 / 10,
          taskLog.summary(workspace: workspace.root) != nil else { return }
    session = newSession()
    print("\u{1B}[2m  the conversation was getting long: continuing in a fresh session with a record of the task\u{1B}[0m")
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
    var prompt = line.trimmingCharacters(in: .whitespaces)
    var typed = prompt  // what the task record keeps: never the shell output that /explain-last shares
    if prompt.isEmpty { continue }
    // "!cd somewhere" would only change a short-lived shell's folder, so it means /cd
    if shell && isStandaloneCd(prompt) { (shell, prompt) = (false, "/" + prompt) }
    if prompt == "/cd" || prompt.hasPrefix("/cd ") {
        let path = String(prompt.dropFirst(3)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\ ", with: " ")
        switch workspace.change(to: path) {
        case .failure(let error): print("\u{1B}[33m\(error.message)\u{1B}[0m")
        case .success(let shown):
            print("\u{1B}[2m  now in \(shown)\u{1B}[0m")
            notesForModel.append("The working folder is now \((workspace.root as NSString).lastPathComponent); paths are relative to it.")
            taskLog.note("moved to the folder \((workspace.root as NSString).lastPathComponent)")
        }
        continue
    }
    if shell {
        lastShell = runDirect(prompt)
        continue
    }
    if prompt == "/explain-last" || prompt == "/fix-last" {
        guard let record = lastShell else { print("\u{1B}[33mNo shell command yet: run one with ! first.\u{1B}[0m"); continue }
        let lines = record.output.map { $0.isEmpty ? 0 : $0.split(separator: "\n").count } ?? 0
        print("\u{1B}[2m  sharing `\(record.command)` (exit \(record.exitCode), \(record.output == nil ? "output not captured" : "\(lines) lines of output")) with the model\u{1B}[0m")
        typed = "\(prompt) (exit \(record.exitCode))"  // not the command either: it can hold a token
        if saveSessions && !savingStopped {
            print("\u{1B}[2m  shell output can hold secrets, so this conversation isn't saved from here on (/clear starts a new one)\u{1B}[0m")
        }
        savingStopped = true
        prompt = record.request(fix: prompt == "/fix-last")
    }
    if prompt == "/permissions" || prompt.hasPrefix("/permissions ") {
        switch prompt.dropFirst("/permissions".count).trimmingCharacters(in: .whitespaces) {
        case "auto": autoApprove = true
        case "ask": autoApprove = false
        case "": break
        default: print("\u{1B}[33mUsage: /permissions [ask|auto]\u{1B}[0m"); continue
        }
        tui?.autoApprove = autoApprove
        print(autoApprove
            ? "\u{1B}[33m  auto: the model's commands and file changes run without asking (/permissions ask to turn it off)\u{1B}[0m"
            : "\u{1B}[2m  ask: every command and file change the model wants is shown first and needs your y (/permissions auto to skip that)\u{1B}[0m")
        continue
    }
    if prompt == "/undo" {
        let (message, undone) = journal.undoLatest()
        print((undone ? "" : "\u{1B}[33m") + message + "\u{1B}[0m")
        if undone {
            notesForModel.append("The user ran /undo: " + message)
            taskLog.note("the user ran /undo: " + message)
        }
        continue
    }
    if prompt == "/sessions" || prompt.hasPrefix("/sessions delete") {
        let saved = sessionStore.list()
        if let number = Int(prompt.dropFirst("/sessions delete".count).trimmingCharacters(in: .whitespaces)), prompt.hasPrefix("/sessions delete") {
            guard number >= 1, number <= saved.count else { print("\u{1B}[33mNo session \(number).\u{1B}[0m"); continue }
            try? sessionStore.delete(saved[number - 1].id)
            if saved[number - 1].id == sessionID { savingStopped = true }  // the next answer would save it again
            print("\u{1B}[2m  deleted \"\(TaskLog.short(saved[number - 1].title, 60))\"\u{1B}[0m")
            continue
        }
        if saved.isEmpty { print("\u{1B}[2m  no saved sessions\(saveSessions ? "" : " (saving is off: --no-save)")\u{1B}[0m"); continue }
        print(saved.prefix(20).enumerated().map { sessionLine($0.offset + 1, $0.element) }.joined(separator: "\n"))
        print("\u{1B}[2m  /resume <number> to continue one, /sessions delete <number> to remove it\u{1B}[0m")
        continue
    }
    if prompt.hasPrefix("/resume") {
        let saved = sessionStore.list()
        guard let number = Int(prompt.dropFirst("/resume".count).trimmingCharacters(in: .whitespaces)), number >= 1, number <= saved.count else {
            print("\u{1B}[33mUsage: /resume <number>, from /sessions.\u{1B}[0m")
            continue
        }
        let resumed = saved[number - 1]
        if FileManager.default.fileExists(atPath: resumed.workspace) {
            workspace.root = resumed.workspace
        } else {
            print("\u{1B}[33m  its folder \(Workspace.tilde(resumed.workspace)) is gone; staying in \(Workspace.tilde(workspace.root))\u{1B}[0m")
        }
        (sessionID, sessionTitle, exchanges, lastShell, savingStopped) = (resumed.id, resumed.title, resumed.exchanges, nil, false)
        taskLog.restore(resumed.task)
        resumeRecap = resumed.recap()
        session = newSession()
        print("\u{1B}[2m  resumed \"\(TaskLog.short(resumed.title, 60))\" (\(resumed.exchanges.count) exchanges) in \(Workspace.tilde(workspace.root)); nothing was rerun\u{1B}[0m")
        if let last = resumed.exchanges.last {
            print("\u{1B}[2m  last: ❯ \(TaskLog.short(last.request, 80))\n        ● \(TaskLog.short(last.answer, 80))\u{1B}[0m")
        }
        let changed = resumed.filesChangedSince()
        if !changed.isEmpty { print("\u{1B}[33m  changed since: \(changed.map(Workspace.tilde).joined(separator: ", ")) (the model is told to reread them)\u{1B}[0m") }
        continue
    }
    if prompt == "/clear" || prompt == "/reset" {
        taskLog.clear()
        lastShell = nil
        (sessionID, sessionTitle, exchanges, resumeRecap, savingStopped) = (SessionStore.newID(), nil, [], nil, false)
        session = newSession()
        if let tui { tui.clearScreen() } else { print("Session cleared.") }
        continue
    }

    let (attached, attachmentNotes) = attachMentionedFiles(to: prompt, workspace: workspace)
    let message = withNotes(attached)
    for note in attachmentNotes { print("\u{1B}[2m  \(note)\u{1B}[0m") }
    taskLog.request(typed)
    await compactIfNeeded()
    tui?.startWorking()
    let changesBefore = taskLog.changeCount
    var outcome = await send(message)
    var recovery: String?
    if case .failed(let error) = outcome, isContextFull(error) {
        session = newSession()  // starts from the task record
        if taskLog.changeCount == changesBefore {  // nothing happened yet, so asking again can't repeat anything
            print("\u{1B}[2m  the conversation was too long for the model: continuing in a fresh session with a record of the task\u{1B}[0m")
            outcome = await send(message)
        } else {
            recovery = "The model's memory filled up after it had already acted, so nothing is repeated automatically. "
                + "It continues fresh from this record; tell it what to do next:\n" + (taskLog.summary(workspace: workspace.root) ?? "")
        }
    }
    var reply: String
    switch outcome {
    case _ where recovery != nil: reply = "\u{1B}[33m" + recovery! + "\u{1B}[0m"
    case .answer(let text):
        taskLog.answer(text)
        if !savingStopped {
            if sessionTitle == nil { sessionTitle = typed }
            exchanges.append(Exchange(request: typed, answer: text))
            saveSession()
        }
        reply = "● " + renderMarkdown(text).replacingOccurrences(of: "\n", with: "\n  ")
    case .cancelled: reply = "\u{1B}[33mCancelled.\u{1B}[0m"
    case .failed(let error) where isContextFull(error):
        reply = "\u{1B}[33mThis request is too long for the model's memory even in a fresh session; try a shorter one.\u{1B}[0m"
    case .failed(let error): reply = "Error: \(error)"
    }
    tui?.stopWorking()
    print("\n" + reply)
}
tui?.finish()
