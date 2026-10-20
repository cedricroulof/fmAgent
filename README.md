# fmagent

A terminal chat with Apple's on-device Foundation Model that can **run shell commands and write files** on your Mac — the piece missing from the built-in `fm chat`.

```
❯ make a file named src/main.c with a hello world C program

 write src/main.c:
#include <stdio.h>
...
Write this file? [y/N] y

● The file src/main.c has been created.

❯ !cc src/main.c -o hello && ./hello
Hello, world!
```

## Requirements

- Apple silicon Mac with Apple Intelligence enabled
- macOS 26 or later
- Swift 6.2+ (Xcode or the Command Line Tools: `xcode-select --install`)
- A terminal at least 30 rows tall to see the welcome apple, with a font that has Braille characters (macOS falls back to one automatically)

Check the model is ready with `fm available`.

## Install

```sh
git clone https://github.com/cedricroulof/fmAgent.git
cd fmAgent
swift build -c release
cp .build/release/fmagent /usr/local/bin/   # optional, may need sudo
```

## Usage

```sh
fmagent          # asks [y/N] before every command or file write
fmagent --yes    # runs everything without asking — use with care
fmagent --timeout 300   # let commands run by the model take up to 300 s (default 60)
```

In a terminal, fmagent runs full screen with the input box pinned to the bottom. The welcome screen shows a 3D dotted apple that spins until your first prompt and while the model answers it; then the conversation scrolls it away (scrollback keeps everything).

| Input | What it does |
|-------|--------------|
| `!command` | Typing `!` first switches the box to shell mode; the command runs directly in zsh on your terminal with your `~/.zshrc` loaded (aliases and functions work, and so do interactive programs like `vim`) and is never sent to the model. Ctrl-C stops it without leaving fmagent. |
| `@path` | Opens a file picker above the box. ↑/↓ to move, Tab or Enter to insert, Esc to close. Picking a folder lists its content; spaces in names are inserted as `\ `. When you send the message, each `@file` attaches its first 80 lines (at most 3 KB per file, 6 KB per message), marked as data rather than instructions. A dim note shows what was attached, cut short or left out. Folders, missing and binary files are never attached. To mention a path without attaching it, write it without `@`. |
| Paste | A multi-line paste shows as `[Pasted text #1 +17 lines]` and is sent in full when you press Enter; Backspace removes it whole. |
| Tab | Completes the file or folder name under the cursor (opens the picker when there are several matches). |
| ↑ / ↓ | History. ←/→, Home/End, Ctrl-A/E/K/U/W edit the line. |
| `/cd <folder>` | Moves fmagent's working folder (`/cd` alone goes home; `!cd folder` does the same). The model's tools, `!commands`, the `@` picker and attachments all use it, and the model is told on your next message. |
| `/explain-last` | Shares your last `!command`, its folder, exit code and the end of its output (3,000 characters) with the model and asks what happened. A plain `!command` is never shown to the model; only these two commands share it. |
| `/fix-last` | Same, but asks the model to read the files involved and fix the cause with `replaceText` (diff and approval as usual). |
| `/undo` | Reverts the latest file change fmagent made (an edit, overwrite or new file). It only does so if the file is still exactly as fmagent left it; otherwise it refuses and keeps your changes. Repeat to go further back. The model is told on your next message. |
| `/clear` | Clears the screen (back to the welcome apple) and starts a new conversation (`/reset` does the same). Ctrl-L only clears the screen. |
| Ctrl-C / Ctrl-D | Clear the line; on an empty line, quit. While the model works, Ctrl-C cancels the request (and stops any command it is running) and brings back the input box with the conversation kept; press it again to quit. At a [y/N] question it cancels too. |

When input is piped (`echo '!ls' | fmagent`), it falls back to plain line-by-line mode (each line is a separate message).

## Tools given to the model

| Tool | What it does |
|------|--------------|
| `runCommand` | Runs a command with `zsh -c` in fmagent's folder, with stdin from `/dev/null`, so it never waits for the keyboard. Output is read as it arrives: the model sees the first 1 KB and the last 2 KB, with a note of how much was skipped, so huge output can't fill memory. After the timeout (60 s, `--timeout`), the command and everything it started are stopped. The result says whether it exited (with its code), was killed by a signal, timed out, or was cancelled. |
| `writeFile` | Creates a text file (creating missing folders), or rewrites a whole file. Overwriting shows a diff against the current content. Refuses to overwrite non-text files. |
| `replaceText` | Changes part of a file: `oldText` must match exactly once (line numbers copied from `readFile` are ignored). Shows a unified diff and asks before writing. |
| `readFile` | Reads numbered lines of a text file (120 lines or 6 KB per call, very long lines cut) and says where to continue. Explains missing, binary and non-UTF-8 files instead of showing them. |
| `listDirectory` | Lists a folder, folders first, at most 100 entries. |
| `searchFiles` | Finds lines containing some text (literal, case-insensitive) under a folder: at most 30 results and 5,000 files scanned. Skips hidden files and folders, `node_modules`/`build`-style folders, symlinks, binary files and files over 1 MB. |

The three read-only tools run without asking and show a dim line of what they looked at. `writeFile` and `replaceText` always show what will change and ask first (unless `--yes`). A declined, ambiguous or not-found change writes nothing, and if the file changed between the preview and your answer, nothing is written either. Writes are atomic and keep the file's permissions. Every tool resolves paths the same way, against fmagent's working folder: relative paths, `~`, spaces and accents work, and no shell is involved.

The on-device model's context holds 8,192 tokens on macOS 27 (the tools' descriptions use about 700 of them). fmagent keeps a short record of the task from what actually happened, not from what the model says: the goal, files changed, the last command and its result, declined actions, and the last request and answer.

- **Before it fills up:** when the conversation passes 70% of the context, fmagent quietly continues in a fresh session that starts from this record. This needs macOS 26.4 or later.
- **If it overflows anyway:** fmagent starts fresh from the record. If nothing had been run or written yet, it asks again automatically. If something had already happened, it shows the record and lets you decide, so nothing is ever done twice.

`/clear` forgets the record.

## Safety

Every command and file write is shown before it runs and needs your approval (one key: `y` approves, anything else declines), unless you pass `--yes`. Commands run with your user's permissions, and `writeFile` overwrites existing files. The model is small and sometimes picks the wrong command, so read before you approve.

## Limitations

- The on-device model is small: it sometimes picks the wrong command, and code it writes may not compile. Run it yourself with `!` (e.g. `!rustc src/main.rs`) to check.
- `!commands` run under `script(1)` so their output can be captured while they keep a real terminal. The recording goes to a private temporary file that is deleted as soon as the command ends; only the end of the latest command's output stays in memory, until the next `!command` or `/clear`. Full-screen programs (`vim`, `less`, `top`) aren't captured.
- Each `!command` runs in its own shell, so shell state like `export` or `alias` defined in one doesn't carry to the next. `!cd` is the exception: it moves fmagent's working folder.

## Tests

```sh
swift test
```

The tests call the tools directly and do not need the model. With only the Command Line Tools installed, `Package.swift` passes the Swift Testing plugin path the build system sometimes leaves out.

## License

MIT
