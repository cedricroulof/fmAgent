import Foundation
import FoundationModels

public let maxOutput = 3000  // the on-device model's context is small, so keep tool output small

public func runShell(_ command: String, in directory: String? = nil) -> (output: String, status: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", command]
    if let directory { p.currentDirectoryURL = URL(fileURLWithPath: directory) }
    p.standardInput = FileHandle.nullDevice  // never hang waiting on the terminal
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("failed to launch: \(error)", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()  // read before wait to avoid pipe deadlock
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
}

public func truncated(_ s: String) -> String {
    s.count <= maxOutput ? s : "[...truncated \(s.count - maxOutput) chars...]\n" + s.suffix(maxOutput)
}

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
    public let description = "Create or overwrite a text file with the given content. Use this instead of shell commands to write files."
    public let parameters = schema("WriteFileArguments", [
        text("path", "File path, relative to the current directory or absolute"),
        text("content", "The full text content of the file"),
    ])

    public func call(arguments: GeneratedContent) async throws -> String {
        let path = try arguments.value(String.self, forProperty: "path")
        let content = try arguments.value(String.self, forProperty: "content")
        let target = context.workspace.resolve(path)
        context.willRun()
        print("\n\u{1B}[33m write \(path):\u{1B}[0m\n\u{1B}[2m\(content)\u{1B}[0m")
        guard context.approve("Write this file?") else { return "The user declined to write this file. Do not write it again; answer without it." }
        do {
            try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try content.write(toFile: target, atomically: true, encoding: .utf8)
            return "Wrote \(content.utf8.count) bytes to \(path)."
        } catch {
            let message = "Failed to write \(path): \(error.localizedDescription)"
            print("\u{1B}[31m\(message)\u{1B}[0m")
            return message
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
        guard context.approve("Run this command?") else { return "The user declined to run this command. Do not run it again; answer without it." }
        let (out, status) = runShell(cmd, in: context.workspace.root)
        print("\u{1B}[2m\(truncated(out))\u{1B}[0m(exit \(status))")
        return "exit code: \(status)\n\(truncated(out))"
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
    public let description = "Find lines containing some text in the files under a folder. Use it instead of grep."
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
