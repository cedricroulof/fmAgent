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
```

In a terminal, fmagent runs full screen with the input box pinned to the bottom. The welcome screen shows a 3D dotted apple that spins until your first prompt and while the model answers it; then the conversation scrolls it away (scrollback keeps everything).

| Input | What it does |
|-------|--------------|
| `!command` | Typing `!` first switches the box to shell mode; the command runs directly in zsh on your terminal (interactive programs like `vim` work) and is never sent to the model. Ctrl-C stops it without leaving fmagent. |
| `@path` | Opens a file picker above the box. ↑/↓ to move, Tab or Enter to insert, Esc to close. Picking a folder lists its content. The model receives the plain path, without the `@`. |
| Tab | Completes the file or folder name under the cursor (opens the picker when there are several matches). |
| ↑ / ↓ | History. ←/→, Home/End, Ctrl-A/E/K/U/W edit the line. |
| `/clear` | Clears the screen (back to the welcome apple) and starts a new conversation (`/reset` does the same). Ctrl-L only clears the screen. |
| Ctrl-C / Ctrl-D | Clear the line; on an empty line, quit. Ctrl-C while the model works also quits. |

When input is piped (`echo '!ls' | fmagent`), it falls back to plain line-by-line mode.

## Tools given to the model

| Tool | What it does |
|------|--------------|
| `runCommand` | Runs a command with `zsh -c`, returns the exit code and combined stdout/stderr (last 3000 characters). Stdin is `/dev/null`, so interactive commands never hang. |
| `writeFile` | Creates or overwrites a text file with the given content, creating missing folders. Multi-line files are written directly instead of through shell quoting. Errors are shown in red. |

The on-device model has a context window of about 4k tokens. When it fills up, the session resets automatically.

## Safety

Every command and file write is shown before it runs and needs your approval, unless you pass `--yes`. Commands run with your user's permissions, and `writeFile` overwrites existing files. The model is small and sometimes picks the wrong command, so read before you approve.

## Limitations

- The on-device model is small: it sometimes picks the wrong command, and code it writes may not compile. Run it yourself with `!` (e.g. `!rustc src/main.rs`) to check.
- Each `!command` runs in its own shell, so `!cd somewhere` doesn't change fmagent's folder, and your `.zshrc` aliases aren't loaded.
- Pasting text that contains newlines sends each line as a separate message.

## Tests

```sh
swift test
```

The tests call the tools directly and do not need the model. With only the Command Line Tools installed, `Package.swift` passes the Swift Testing plugin path the build system sometimes leaves out.

## License

MIT
