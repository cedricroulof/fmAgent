// Full-screen terminal UI: the conversation scrolls above an input box pinned to the bottom.
//
//   scroll region   welcome apple (spins until it may scroll away), then the conversation
//   menu            @ file picker, up to 5 rows, only while open
//   rule / ❯ input / rule / status
import Foundation
import FMAgentCore

let dim = "\u{1B}[2m", bold = "\u{1B}[1m", yellow = "\u{1B}[33m", reset = "\u{1B}[0m"
let pink = "\u{1B}[38;5;205m", lavender = "\u{1B}[38;5;147m", orange = "\u{1B}[38;5;209m"
let clearLine = "\u{1B}[2K"

func move(_ row: Int, _ col: Int) -> String { "\u{1B}[\(row);\(col)H" }

/// Keeps the end of `text` (the useful part of a path) within `width` columns.
func fitted(_ text: String, _ width: Int) -> String {
    text.count <= width ? text : "…" + text.suffix(max(0, width - 1))
}

/// Unbuffered write, safe to mix with print() and with the spinner thread.
func writeOut(_ s: String) {
    fflush(stdout)
    var bytes = Array(s.utf8)[...]
    while !bytes.isEmpty {
        let n = bytes.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        bytes = bytes.dropFirst(n)
    }
}

/// The welcome apple. It may only be redrawn while nothing can have scrolled it, so it is `settle`d (turned to
/// face front and left alone) before any output that could move it.
final class WelcomeApple: @unchecked Sendable {
    private let lock = NSLock()
    private var row: Int?
    private var tick = 0

    func place(at row: Int?) { lock.withLock { self.row = row; tick = 0 } }
    var isPlaced: Bool { lock.withLock { row != nil } }

    func spin() {
        lock.withLock {
            guard let row else { return }
            tick += 1
            draw(row: row, angle: Double(tick) * .pi / 18)
        }
    }

    func settle() {
        lock.withLock {
            guard let row else { return }
            draw(row: row, angle: 0)
            self.row = nil
        }
    }

    private func draw(row: Int, angle: Double) {
        let lines = AppleLogo.frame(angle: angle).enumerated().map { move(row + $0.offset, 3) + $0.element }
        writeOut("\u{1B}7" + lines.joined() + "\u{1B}8")  // save/restore: output keeps flowing where it was
    }
}

let welcomeApple = WelcomeApple()

enum Key { case char(Character), paste(String), enter, tab, backspace, delete, up, down, left, right, home, end, esc, ctrl(UInt8), resize, tick, eof, none }

// Keys read while waiting for a cursor-position report, replayed before anything new from stdin.
// Only touched from the main thread (the line editor).
nonisolated(unsafe) var pendingInput: [UInt8] = []

func readByte(timeoutMs: Int32 = -1) -> UInt8? {
    if !pendingInput.isEmpty { return pendingInput.removeFirst() }
    return readStdinByte(timeoutMs: timeoutMs)
}

func readStdinByte(timeoutMs: Int32 = -1) -> UInt8? {
    if timeoutMs >= 0 {
        var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&fd, 1, timeoutMs) > 0 else { return nil }
    }
    var byte: UInt8 = 0
    return Darwin.read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
}

/// With a timeout, returns `.tick` when no key arrives in time (used to animate).
func readKey(timeoutMs: Int32 = -1) -> Key {
    if timeoutMs >= 0 && pendingInput.isEmpty {
        var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&fd, 1, timeoutMs)
        if ready == 0 { return .tick }
        if ready < 0 { return errno == EINTR ? .resize : .eof }
    }
    guard let b = readByte() else { return errno == EINTR ? .resize : .eof }
    switch b {
    case 0x0D, 0x0A: return .enter
    case 0x09: return .tab
    case 0x7F, 0x08: return .backspace
    case 0x1B:
        guard let b2 = readByte(timeoutMs: 30), b2 == 0x5B || b2 == 0x4F else { return .esc }
        var seq = ""
        while let c = readByte(timeoutMs: 30) {
            seq.append(Character(UnicodeScalar(c)))
            if (0x40...0x7E).contains(c) { break }
        }
        switch seq {
        case "A": return .up
        case "B": return .down
        case "C": return .right
        case "D": return .left
        case "H", "1~", "7~": return .home
        case "F", "4~", "8~": return .end
        case "3~": return .delete
        case "200~":  // bracketed paste: everything up to ESC [201~ is pasted text, newlines included
            let end = Array("\u{1B}[201~".utf8)
            var pasted: [UInt8] = []
            while let c = readByte(timeoutMs: 500) {
                pasted.append(c)
                if pasted.count >= end.count && Array(pasted.suffix(end.count)) == end { break }
            }
            if Array(pasted.suffix(end.count)) == end { pasted.removeLast(end.count) }
            return .paste(String(decoding: pasted, as: UTF8.self))
        default: return .none
        }
    case 0..<0x20: return .ctrl(b)
    default:
        let length = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
        var bytes = [b]
        for _ in 1..<length { if let c = readByte(timeoutMs: 30) { bytes.append(c) } }
        return String(decoding: bytes, as: UTF8.self).first.map { .char($0) } ?? .none
    }
}

/// Animates the status line (and the welcome apple, while it is placed) on a background queue while the model works.
final class Spinner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fmagent.spinner")
    private let timer: DispatchSourceTimer
    private var tick = 0

    init(statusRow: Int) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(70))
        timer.setEventHandler { [unowned self] in draw(statusRow: statusRow) }
        timer.resume()
    }

    private func draw(statusRow: Int) {
        tick += 1
        welcomeApple.spin()
        let glyphs = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
        let status = move(statusRow, 1) + clearLine + "  \(orange)\(glyphs[tick / 2 % glyphs.count]) Thinking…\(reset)"
        writeOut("\u{1B}7" + status + "\u{1B}8")
    }

    func stop() { queue.sync { timer.cancel() } }
}

/// The running spinner, reachable from tool threads: it is stopped before a tool prints or asks for approval,
/// so its background writes never interleave with tool output or the echo of the user's answer.
final class SpinnerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var spinner: Spinner?

    func start(statusRow: Int) { lock.withLock { spinner = Spinner(statusRow: statusRow) } }

    func stop() {
        let running = lock.withLock { () -> Spinner? in
            defer { spinner = nil }
            return spinner
        }
        running?.stop()
    }
}

let runningSpinner = SpinnerSlot()

final class TerminalUI {
    let autoApprove: Bool
    let workspace: Workspace
    let cwd: String
    var rows = 24, cols = 80
    var menuRows = 0
    var outRow = 1, outCol = 1  // where the next output line goes inside the scroll region
    var cooked = termios()
    var history: [String] = []

    // line editor state
    var buf: [Character] = []
    var cur = 0
    var shell = false
    var items: [String] = []
    var sel = 0
    var forcedMenu = false  // Tab opened the menu on a plain word
    var menuDismissed = false
    var histIdx = 0
    var pastes = PasteStore()

    init(autoApprove: Bool, workspace: Workspace) {
        self.autoApprove = autoApprove
        self.workspace = workspace
        var cwd = workspace.root
        if cwd.hasPrefix(NSHomeDirectory()) { cwd = "~" + cwd.dropFirst(NSHomeDirectory().count) }
        self.cwd = cwd
        tcgetattr(STDIN_FILENO, &cooked)
    }

    var regionBottom: Int { rows - 4 - menuRows }

    func updateSize() {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_row > 0 { rows = Int(size.ws_row); cols = Int(size.ws_col) }
    }

    func start() {
        // Ctrl-C while the model works: put the terminal back before quitting
        signal(SIGINT) { _ in
            let restore: StaticString = "\u{1B}[r\u{1B}[?2004l\u{1B}[999;1H\r\n"
            restore.withUTF8Buffer { _ = Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            _exit(130)
        }
        updateSize()
        clearScreen()
    }

    func finish() { writeOut("\u{1B}[r" + move(rows, 1) + "\r\n") }

    /// Clears everything and shows the welcome screen: the apple, spinning until the first prompt.
    func clearScreen() {
        writeOut("\u{1B}[r\u{1B}[2J\u{1B}[H")
        menuRows = 0
        (outRow, outCol) = (1, 1)
        guard rows >= AppleLogo.height + 12 else { welcomeApple.place(at: nil); return }
        let top = 2, mid = top + AppleLogo.height / 2, textCol = AppleLogo.width + 7
        welcomeApple.place(at: top)
        welcomeApple.settle()  // draw it once facing front…
        welcomeApple.place(at: top)  // …and keep it animatable
        writeOut(move(mid - 1, textCol) + "\(bold)fmagent\(reset)" + move(mid, textCol) + "\(dim)Apple Foundation Model · on-device\(reset)"
            + move(mid + 1, textCol) + "\(dim)\(fitted(cwd, cols - textCol))\(reset)")
        outRow = top + AppleLogo.height + 1
        writeOut(move(outRow, 1))  // the next read() takes the output position from the cursor
    }

    func setRegion() { writeOut("\u{1B}[1;\(regionBottom)r") }

    func startWorking() { runningSpinner.start(statusRow: rows) }

    func stopWorking() {
        runningSpinner.stop()
        welcomeApple.settle()  // the reply may scroll it away
        writeOut("\u{1B}7" + move(rows, 1) + clearLine + statusLine() + "\u{1B}8")
    }

    // MARK: input

    func enterRaw() {
        var raw = cooked
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        writeOut("\u{1B}[?2004h")  // bracketed paste, so pasted newlines don't send the line
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        sigaction(SIGWINCH, &action, nil)  // no SA_RESTART: a resize interrupts read() so the box is redrawn
    }

    func leaveRaw() {
        tcsetattr(STDIN_FILENO, TCSANOW, &cooked)
        writeOut("\u{1B}[?2004l")
        signal(SIGWINCH, SIG_DFL)
    }

    func cursorPosition() -> (Int, Int)? {
        writeOut("\u{1B}[6n")
        var received: [UInt8] = []
        while let b = readStdinByte(timeoutMs: 300) {
            received.append(b)
            if let report = extractCursorReport(from: received) {
                pendingInput += report.rest
                return (report.row, report.col)
            }
        }
        pendingInput += received  // no report: whatever arrived is the user's typing
        return nil
    }

    /// Reads one line in the bottom box. Returns nil to quit; `shell` is true for `!` commands.
    func read() -> (text: String, shell: Bool)? {
        updateSize()
        enterRaw()
        if let (row, col) = cursorPosition() { (outRow, outCol) = (row, col) }
        menuRows = 0
        if outRow > regionBottom { (outRow, outCol) = (regionBottom, 1) }
        setRegion()
        (buf, cur, shell, sel, forcedMenu, menuDismissed, histIdx) = ([], 0, false, 0, false, false, history.count)

        while true {
            render()  // also after each animation tick: puts the cursor back on the prompt explicitly
            let key = readKey(timeoutMs: welcomeApple.isPlaced ? 70 : -1)
            if case .char = key { menuDismissed = false }
            if case .backspace = key { menuDismissed = false }
            switch key {
            case .tick:
                welcomeApple.spin()
            case .eof:
                leaveRaw()
                return nil
            case .resize:
                updateSize()
                outRow = min(outRow, regionBottom)
                setRegion()
            case .char("!") where buf.isEmpty && !shell:
                shell = true
            case .char(let ch):
                buf.insert(ch, at: cur)
                cur += 1
                sel = 0
                if ch == " " { forcedMenu = false }
            case .paste(let text):
                let inserted = pastes.insert(text)
                buf.insert(contentsOf: inserted, at: cur)
                cur += inserted.count
            case .backspace:
                if let placeholder = pastes.placeholder(endingAt: String(buf[..<cur])) {
                    buf.removeSubrange((cur - placeholder.count)..<cur)
                    cur -= placeholder.count
                } else if cur > 0 { buf.remove(at: cur - 1); cur -= 1; sel = 0 } else if buf.isEmpty { shell = false }
            case .delete:
                if cur < buf.count { buf.remove(at: cur) }
            case .ctrl(3), .ctrl(4):  // Ctrl-C / Ctrl-D: clear the line, leave shell mode, then quit
                if !buf.isEmpty { (buf, cur) = ([], 0) } else if shell { shell = false } else {
                    leaveRaw()
                    return nil
                }
            case .left: cur = max(0, cur - 1)
            case .right: cur = min(buf.count, cur + 1)
            case .home, .ctrl(1): cur = 0
            case .end, .ctrl(5): cur = buf.count
            case .up:
                if !items.isEmpty { sel = (sel + items.count - 1) % items.count } else if histIdx > 0 { histIdx -= 1; load(history[histIdx]) }
            case .down:
                if !items.isEmpty { sel = (sel + 1) % items.count } else if histIdx < history.count {
                    histIdx += 1
                    load(histIdx == history.count ? "" : history[histIdx])
                }
            case .tab:
                if !items.isEmpty { accept() } else {
                    let matches = completions(for: currentToken().text)
                    if matches.count == 1 { items = matches; sel = 0; accept() } else if matches.count > 1 { forcedMenu = true }
                }
            case .enter:
                if !items.isEmpty { accept(); continue }
                if buf.allSatisfy(\.isWhitespace) && !shell { continue }
                return submit()
            case .esc:
                if !items.isEmpty { menuDismissed = true; forcedMenu = false } else if buf.isEmpty { shell = false }
            case .ctrl(11): buf.removeSubrange(cur...)  // Ctrl-K
            case .ctrl(21): buf.removeSubrange(..<cur); cur = 0  // Ctrl-U
            case .ctrl(23):  // Ctrl-W deletes the previous word
                var start = cur
                while start > 0 && buf[start - 1] == " " { start -= 1 }
                while start > 0 && buf[start - 1] != " " { start -= 1 }
                buf.removeSubrange(start..<cur)
                cur = start
            case .ctrl(12):  // Ctrl-L
                clearScreen()
                setRegion()
            default: break
            }
        }
    }

    func load(_ entry: String) {
        shell = entry.hasPrefix("!")
        buf = Array(shell ? String(entry.dropFirst()) : entry)
        cur = buf.count
    }

    /// The word before the cursor; a `\ ` (escaped space, as in picked paths) doesn't end it.
    func currentToken() -> (start: Int, text: String) {
        var start = cur
        while start > 0 && !(buf[start - 1].isWhitespace && (start < 2 || buf[start - 2] != "\\")) { start -= 1 }
        return (start, String(buf[start..<cur]))
    }

    /// Completions for the word before the cursor, without its `@` and with `\ ` read as a space.
    func completions(for token: String) -> [String] {
        pathCompletions(for: token.replacingOccurrences(of: "\\ ", with: " "), in: workspace.root)
    }

    func accept() {
        let (start, token) = currentToken()
        let pick = (token.hasPrefix("@") ? "@" : "") + items[sel].replacingOccurrences(of: " ", with: "\\ ")
        buf.replaceSubrange(start..<cur, with: Array(pick))
        cur = start + pick.count
        if !pick.hasSuffix("/") {  // a file ends the word; a directory keeps the menu open on its content
            buf.insert(" ", at: cur)
            cur += 1
            forcedMenu = false
        }
        sel = 0
    }

    func submit() -> (text: String, shell: Bool) {
        let text = String(buf)
        let wasShell = shell
        (buf, cur, shell, items) = ([], 0, false, [])
        setMenuRows(0)
        render()
        leaveRaw()
        var s = move(outRow, outCol) + (outCol > 1 ? "\r\n" : "")
        if outRow > 1 { s += "\r\n" }
        s += (wasShell ? "\(pink)!\(reset) " : "\(dim)❯\(reset) ") + text + "\r\n"
        // a shell command's output, or a nearly full screen, could scroll the apple: stop animating it
        if wasShell || regionBottom - outRow < 6 { welcomeApple.settle() }
        writeOut(s)
        history.append((wasShell ? "!" : "") + text)
        return (pastes.expand(text), wasShell)
    }

    // MARK: drawing

    func statusLine() -> String {
        if shell { return "  \(pink)! for shell mode\(reset)" }
        let mode = autoApprove ? "\(yellow)▸▸ auto-approve on\(reset)" : "\(dim)asks before running commands\(reset)"
        return "  \(mode)\(dim) · ! for shell · @ for files · /clear · ctrl-c to quit\(reset)"
    }

    /// Grows or shrinks the menu area above the box, scrolling output up first so nothing is drawn over.
    func setMenuRows(_ count: Int) {
        guard count != menuRows else { return }
        if count > menuRows {
            let overlap = outRow - (rows - 4 - count)
            if overlap > 0 {
                welcomeApple.settle()
                writeOut(move(regionBottom, 1) + String(repeating: "\n", count: overlap))
                outRow -= overlap
            }
        } else {
            writeOut(((rows - 3 - menuRows)..<(rows - 3 - count)).map { move($0, 1) + clearLine }.joined())
        }
        menuRows = count
        setRegion()
    }

    func render() {
        let token = currentToken().text
        if menuDismissed { items = [] }
        else if token.hasPrefix("@") { items = completions(for: String(token.dropFirst())) }
        else if forcedMenu { items = completions(for: token) }
        else { items = [] }
        if sel >= items.count { sel = 0 }
        setMenuRows(min(items.count, 5))

        let accent = shell ? pink : dim
        let rule = accent + String(repeating: "─", count: cols) + reset
        var s = "\u{1B}[?25l"
        let first = max(0, sel - 4)
        for i in 0..<menuRows {
            let index = first + i
            let name = String(items[index].prefix(max(0, cols - 6)))
            s += move(rows - 3 - menuRows + i, 1) + clearLine
            s += index == sel ? "  \(lavender)❯ + \(name)\(reset)" : "    \(dim)+ \(name)\(reset)"
        }
        let width = max(1, cols - 3)
        let start = max(0, cur - width + 1)  // scroll long input so the cursor stays visible
        let visible = String(buf[start..<min(buf.count, start + width)])
        s += move(rows - 3, 1) + clearLine + rule
        s += move(rows - 2, 1) + clearLine + (shell ? "\(pink)!\(reset) " : "\(bold)❯\(reset) ") + visible
        s += move(rows - 1, 1) + clearLine + rule
        s += move(rows, 1) + clearLine + statusLine()
        writeOut(s + move(rows - 2, 3 + cur - start) + "\u{1B}[?25h")
    }
}
