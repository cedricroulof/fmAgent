import Foundation

public enum CommandOutcome: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut(TimeInterval)
    case cancelled
    case failedToStart(String)
}

public struct CommandResult: Sendable {
    public let outcome: CommandOutcome
    public let output: String  // the start and the end of what was printed, with a note of what was skipped
    public let totalBytes: Int

    /// One line the model and the user can read.
    public var summary: String {
        switch outcome {
        case .exited(let code): "exit code: \(code)"
        case .signaled(let signal): "killed by signal \(signal)"
        case .timedOut(let seconds): "timed out after \(Int(seconds))s; the command and its child processes were stopped"
        case .cancelled: "cancelled by the user; the command and its child processes were stopped"
        case .failedToStart(let reason): "could not start: \(reason)"
        }
    }
}

/// Runs `command` with `zsh -c` in its own process group, stdin from /dev/null, stdout and stderr combined.
/// Output is read as it arrives and only `headBytes` + `tailBytes` are kept, so memory stays bounded. The whole
/// group (the command and anything it started) is stopped on timeout, on cancellation, and once the command has
/// exited (background leftovers). Programs that move themselves to another group or session can escape this.
public func runCommand(_ command: String, in directory: String? = nil, timeout: TimeInterval = 60,
                       isCancelled: () -> Bool = { false }, headBytes: Int = 1_000, tailBytes: Int = 2_000) -> CommandResult {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return CommandResult(outcome: .failedToStart(String(cString: strerror(errno))), output: "", totalBytes: 0) }
    let (readEnd, writeEnd) = (fds[0], fds[1])

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)  // never wait for the keyboard
    posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
    posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
    posix_spawn_file_actions_addclose(&actions, readEnd)
    posix_spawn_file_actions_addclose(&actions, writeEnd)
    if let directory { posix_spawn_file_actions_addchdir(&actions, directory) }

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setpgroup(&attr, 0)  // its own group, so it and its children can be stopped together
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for signal in [SIGINT, SIGQUIT, SIGPIPE] { sigaddset(&defaults, signal) }  // not fmagent's ignored signals
    posix_spawnattr_setsigdefault(&attr, &defaults)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))

    let argv = ["/bin/zsh", "-c", command].map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let spawnError = posix_spawn(&pid, "/bin/zsh", &actions, &attr, argv, environ)
    close(writeEnd)
    defer { close(readEnd) }
    guard spawnError == 0 else { return CommandResult(outcome: .failedToStart(String(cString: strerror(spawnError))), output: "", totalBytes: 0) }

    var head: [UInt8] = [], tail: [UInt8] = [], total = 0
    var status: Int32 = 0, exited = false, exitTime = Date.distantFuture
    var stoppedBecause: CommandOutcome?
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 65_536)

    func stopGroup() {
        kill(-pid, SIGTERM)
        for _ in 0..<20 where !exited {  // up to 2 s to exit cleanly
            if waitpid(pid, &status, WNOHANG) == pid { exited = true } else { usleep(100_000) }
        }
        kill(-pid, SIGKILL)
    }

    while true {
        var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
        if poll(&poller, 1, 100) > 0 {
            let count = read(readEnd, &buffer, buffer.count)
            if count <= 0 { break }  // end of output: everyone holding the pipe is gone
            total += count
            let chunk = buffer[0..<count]
            let toHead = min(count, headBytes - head.count)
            head.append(contentsOf: chunk.prefix(toHead))
            tail.append(contentsOf: chunk.dropFirst(toHead))
            if tail.count > tailBytes * 2 { tail = Array(tail.suffix(tailBytes)) }  // a fresh copy: a slice would keep growing the old buffer
        }
        if !exited && waitpid(pid, &status, WNOHANG) == pid { exited = true; exitTime = Date() }
        if exited && Date().timeIntervalSince(exitTime) > 0.5 { break }  // leftovers still hold the pipe open
        if !exited && Date() > deadline { stoppedBecause = .timedOut(timeout); break }
        if !exited && isCancelled() { stoppedBecause = .cancelled; break }
    }
    if stoppedBecause != nil { stopGroup() }
    kill(-pid, SIGKILL)  // background leftovers of a finished command
    if !exited { while waitpid(pid, &status, 0) == -1 && errno == EINTR {} }

    tail = Array(tail.suffix(tailBytes))
    let omitted = total - head.count - tail.count
    let output = String(decoding: head, as: UTF8.self)
        + (omitted > 0 ? "\n[… \(omitted) bytes not shown …]\n" : "") + String(decoding: tail, as: UTF8.self)
    let signal = status & 0x7f
    let outcome = stoppedBecause ?? (signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal))
    return CommandResult(outcome: outcome, output: output, totalBytes: total)
}
