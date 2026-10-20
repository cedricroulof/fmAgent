import Foundation
import FoundationModels

// Schemas are built by hand: the @Generable macro needs full Xcode, not just the Command Line Tools.
func schema(_ name: String, _ properties: [DynamicGenerationSchema.Property]) -> GenerationSchema {
    try! GenerationSchema(root: DynamicGenerationSchema(name: name, properties: properties), dependencies: [])
}

func text(_ name: String, _ description: String, optional: Bool = false) -> DynamicGenerationSchema.Property {
    .init(name: name, description: description, schema: DynamicGenerationSchema(type: String.self), isOptional: optional)
}

func number(_ name: String, _ description: String) -> DynamicGenerationSchema.Property {
    .init(name: name, description: description, schema: DynamicGenerationSchema(type: Int.self), isOptional: true)
}

/// A dim one-line note of what a read-only tool looked at.
func note(_ s: String) { print("\u{1B}[2m  \(s)\u{1B}[0m") }

// The small model can't reliably pack multi-line file contents into a shell command, so writing gets its own tool.
public struct WriteFile: Tool {
    public let context: ToolContext
    public init(_ context: ToolContext) { self.context = context }

    public let name = "writeFile"
    public let description = "Create a new text file, or rewrite a whole file, with the given content."
    public let parameters = schema("WriteFileArguments", [
        text("path", "File path, relative to the current directory or absolute"),
        text("content", "The full text content of the file"),
    ])

    public func call(arguments: GeneratedContent) async throws -> String {
        let path = try arguments.value(String.self, forProperty: "path")
        let content = try arguments.value(String.self, forProperty: "content")
        context.willRun()
        switch proposeWrite(at: context.workspace.resolve(path), shown: path, content: content) {
        case .failure(let error): return failed(error.message)
        case .success(let edit) where edit.original == nil:
            print("\n\u{1B}[33m create \(path):\u{1B}[0m\n\u{1B}[2m\(content)\u{1B}[0m")
            return confirm(edit, context, question: "Write this file?", done: "Wrote \(content.utf8.count) bytes to \(path).")
        case .success(let edit):
            print("\n\u{1B}[33m overwrite \(path):\u{1B}[0m\n" + coloredDiff(edit.diff))
            return confirm(edit, context, question: "Overwrite this file?", done: "Overwrote \(path) (\(content.utf8.count) bytes).")
        }
    }
}

func failed(_ message: String) -> String {
    print("\u{1B}[31m\(message)\u{1B}[0m")
    return message
}

/// Asks before writing a previewed edit; a declined or stale edit leaves the file untouched.
func confirm(_ edit: EditProposal, _ context: ToolContext, question: String, done: String) -> String {
    guard context.approve(question) else {
        context.log.declined("change \(edit.shown)")
        return "The user declined this change; nothing was written. Do not retry it; answer without it."
    }
    switch apply(edit) {
    case .failure(let error): return failed(error.message)
    case .success:
        context.journal.record(edit)
        context.log.fileChanged(edit.shown)
        return done
    }
}

/// Changes one exact piece of a file, previewed as a diff.
public struct ReplaceText: Tool {
    public let context: ToolContext
    public init(_ context: ToolContext) { self.context = context }

    public let name = "replaceText"
    public let description = "Change part of a file: replace oldText, copied exactly from readFile and found once, with newText."
    public let parameters = schema("ReplaceTextArguments", [
        text("path", "File path"),
        text("oldText", "The exact current text to replace, with enough lines to be unique"),
        text("newText", "The replacement text"),
    ])

    public func call(arguments: GeneratedContent) async throws -> String {
        let path = try arguments.value(String.self, forProperty: "path")
        let oldText = try arguments.value(String.self, forProperty: "oldText")
        let newText = try arguments.value(String.self, forProperty: "newText")
        context.willRun()
        switch proposeReplacement(at: context.workspace.resolve(path), shown: path, oldText: oldText, newText: newText) {
        case .failure(let error): return failed(error.message)
        case .success(let edit):
            print("\n\u{1B}[33m edit \(path):\u{1B}[0m\n" + coloredDiff(edit.diff))
            return confirm(edit, context, question: "Apply this edit?", done: "Edited \(path).")
        }
    }
}

public struct RunCommand: Tool {
    public let context: ToolContext
    public init(_ context: ToolContext) { self.context = context }

    public let name = "runCommand"
    public let description = """
        Run a command on the user's Mac to inspect or change the system; returns its exit code and output. \
        It already runs in zsh: do not wrap it in `zsh -c`. Never use it to show text or code to the user.
        """
    public let parameters = schema("RunCommandArguments", [text("command", "The exact zsh command line to execute")])

    public func call(arguments: GeneratedContent) async throws -> String {
        let cmd = try arguments.value(String.self, forProperty: "command")
        context.willRun()
        print("\n\u{1B}[33m$ \(cmd)\u{1B}[0m")
        guard context.approve("Run this command?") else {
            context.log.declined("run `\(cmd)`")
            return "The user declined to run this command. Do not run it again; answer without it."
        }
        let result = runCommand(cmd, in: context.workspace.root, timeout: context.commandTimeout, isCancelled: context.isCancelled)
        context.log.commandRan(cmd, result.summary)
        print("\u{1B}[2m\(result.output)\u{1B}[0m(\(result.summary))")
        return result.summary + "\n" + result.output
    }
}

// Read-only tools: no approval, they only report what they looked at.

public struct ReadFile: Tool {
    public let context: ToolContext
    public init(_ context: ToolContext) { self.context = context }

    public let name = "readFile"
    public let description = "Read numbered lines of a text file. Use it instead of cat."
    public let parameters = schema("ReadFileArguments", [
        text("path", "File path"),
        number("startLine", "First line to read, from 1"),
        number("lineCount", "How many lines, at most \(InspectionLimits.readLines)"),
    ])

    public func call(arguments: GeneratedContent) async throws -> String {
        let path = try arguments.value(String.self, forProperty: "path")
        let start = try arguments.value(Int?.self, forProperty: "startLine") ?? 1
        let count = try arguments.value(Int?.self, forProperty: "lineCount") ?? InspectionLimits.readLines
        context.willRun()
        let result = readFileExcerpt(context.workspace.resolve(path), shown: path, startLine: start, lineCount: count)
        note("read " + (result.split(separator: "\n").first.map(String.init) ?? path))
        return result
    }
}

public struct ListDirectory: Tool {
    public let context: ToolContext
    public init(_ context: ToolContext) { self.context = context }

    public let name = "listDirectory"
    public let description = "List the files and folders in a directory. Use it instead of ls."
    public let parameters = schema("ListDirectoryArguments", [text("path", "Directory path; \".\" is the current directory")])

    public func call(arguments: GeneratedContent) async throws -> String {
        let path = try arguments.value(String.self, forProperty: "path")
        context.willRun()
        note("list \(path)")
        return listDirectory(context.workspace.resolve(path), shown: path)
    }
}

public struct SearchFiles: Tool {
    public let context: ToolContext
    public init(_ context: ToolContext) { self.context = context }

    public let name = "searchFiles"
    public let description = "Find files whose name or lines contain some text, under a folder. Use it instead of grep or find."
    public let parameters = schema("SearchFilesArguments", [
        text("query", "Text to find (not a regex, case-insensitive)"),
        text("path", "Folder or file to search; defaults to the current directory", optional: true),
    ])

    public func call(arguments: GeneratedContent) async throws -> String {
        let query = try arguments.value(String.self, forProperty: "query")
        let path = try arguments.value(String?.self, forProperty: "path") ?? "."
        context.willRun()
        note("search \"\(query)\" in \(path)")
        return searchFiles(query, in: context.workspace.resolve(path), shown: path, display: context.workspace.display)
    }
}
