# fmagent

A terminal chat with Apple's on-device Foundation Model that can **run shell commands and write files** on your Mac — the piece missing from the built-in `fm chat`.

```
> make a file here named main.c with a hello world C program

 write main.c:
#include <stdio.h>
...
Write this file? [y/N] y
The file "main.c" has been created.
```

## Requirements

- Apple silicon Mac with Apple Intelligence enabled
- macOS 26 or later
- Swift 6.2+ (Xcode or the Command Line Tools: `xcode-select --install`)

Check the model is ready with `fm available`.

## Install

```sh
git clone https://github.com/cedricroulof/fmAgent.git
cd fmAgent
swift build -c release
cp .build/release/fmagent /usr/local/bin/   # optional
```

## Usage

```sh
fmagent          # asks [y/N] before every command or file write
fmagent --yes    # runs everything without asking — use with care
```

In the chat, `/reset` starts a fresh conversation and Ctrl-D quits. The input line supports arrow-key editing, history (↑/↓) and Tab completion of file names and paths. Replies are rendered from Markdown: code blocks, headers, lists, **bold** and `inline code` are shown with terminal colors.

## Tools given to the model

| Tool | What it does |
|------|--------------|
| `runCommand` | Runs a command with `zsh -c`, returns the exit code and combined stdout/stderr (last 3000 characters). Stdin is `/dev/null`, so interactive commands never hang. |
| `writeFile` | Creates or overwrites a text file with the given content. Multi-line files are written directly instead of through shell quoting. |

The on-device model has a context window of about 4k tokens. When it fills up, the session resets automatically.

## Safety

Every command and file write is shown before it runs and needs your approval, unless you pass `--yes`. Commands run with your user's permissions, and `writeFile` overwrites existing files. The model is small and sometimes picks the wrong command, so read before you approve.

## Tests

```sh
swift test
```

The tests call the tools directly and do not need the model.

## License

MIT
