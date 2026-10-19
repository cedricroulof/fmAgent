import Foundation
import FoundationModels

public let maxOutput = 3000  // the on-device context window is ~4k tokens, so keep tool output small

public func runShell(_ command: String) -> (output: String, status: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", command]
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

// The small model can't reliably pack multi-line file contents into a shell command, so writing gets its own tool.
public struct WriteFile: Tool {
    public let approve: @Sendable (String) -> Bool
    public init(approve: @escaping @Sendable (String) -> Bool) { self.approve = approve }

    public let name = "writeFile"
    public let description = "Create or overwrite a text file with the given content. Use this instead of shell commands to write files."

    public let parameters = try! GenerationSchema(root: DynamicGenerationSchema(
        name: "WriteFileArguments",
        properties: [.init(name: "path", description: "File path, relative to the current directory or absolute",
                           schema: DynamicGenerationSchema(type: String.self)),
                     .init(name: "content", description: "The full text content of the file",
                           schema: DynamicGenerationSchema(type: String.self))]
    ), dependencies: [])

    public func call(arguments: GeneratedContent) async throws -> String {
        let path = try arguments.value(String.self, forProperty: "path")
        let content = try arguments.value(String.self, forProperty: "content")
        print("\n\u{1B}[33m write \(path):\u{1B}[0m\n\u{1B}[2m\(content)\u{1B}[0m")
        guard approve("Write this file?") else { return "The user declined to write this file." }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return "Wrote \(content.utf8.count) bytes to \(path)."
        } catch {
            return "Failed to write \(path): \(error.localizedDescription)"
        }
    }
}

public struct RunCommand: Tool {
    public let approve: @Sendable (String) -> Bool
    public init(approve: @escaping @Sendable (String) -> Bool) { self.approve = approve }

    public let name = "runCommand"
    public let description = "Run a zsh shell command on the user's Mac and return its combined stdout/stderr and exit code."

    // Schema built by hand: the @Generable macro needs full Xcode, not just Command Line Tools.
    public let parameters = try! GenerationSchema(root: DynamicGenerationSchema(
        name: "RunCommandArguments",
        properties: [.init(name: "command", description: "The exact zsh command line to execute",
                           schema: DynamicGenerationSchema(type: String.self))]
    ), dependencies: [])

    public func call(arguments: GeneratedContent) async throws -> String {
        let cmd = try arguments.value(String.self, forProperty: "command")
        print("\n\u{1B}[33m$ \(cmd)\u{1B}[0m")
        guard approve("Run this command?") else { return "The user declined to run this command." }
        let (out, status) = runShell(cmd)
        print("\u{1B}[2m\(truncated(out))\u{1B}[0m(exit \(status))")
        return "exit code: \(status)\n\(truncated(out))"
    }
}
