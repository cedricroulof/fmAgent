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
    public let willRun: @Sendable () -> Void  // called before the tool prints anything
    public init(approve: @escaping @Sendable (String) -> Bool, willRun: @escaping @Sendable () -> Void = {}) {
        self.approve = approve
        self.willRun = willRun
    }

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
        willRun()
        print("\n\u{1B}[33m write \(path):\u{1B}[0m\n\u{1B}[2m\(content)\u{1B}[0m")
        guard approve("Write this file?") else { return "The user declined to write this file. Do not write it again; answer without it." }
        do {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return "Wrote \(content.utf8.count) bytes to \(path)."
        } catch {
            let message = "Failed to write \(path): \(error.localizedDescription)"
            print("\u{1B}[31m\(message)\u{1B}[0m")
            return message
        }
    }
}

public struct RunCommand: Tool {
    public let approve: @Sendable (String) -> Bool
    public let willRun: @Sendable () -> Void  // called before the tool prints anything
    public init(approve: @escaping @Sendable (String) -> Bool, willRun: @escaping @Sendable () -> Void = {}) {
        self.approve = approve
        self.willRun = willRun
    }

    public let name = "runCommand"
    public let description = """
        Run a command on the user's Mac to inspect or change the system; returns its exit code and output. \
        It already runs in zsh: do not wrap it in `zsh -c`. Never use it to show text or code to the user.
        """

    // Schema built by hand: the @Generable macro needs full Xcode, not just Command Line Tools.
    public let parameters = try! GenerationSchema(root: DynamicGenerationSchema(
        name: "RunCommandArguments",
        properties: [.init(name: "command", description: "The exact zsh command line to execute",
                           schema: DynamicGenerationSchema(type: String.self))]
    ), dependencies: [])

    public func call(arguments: GeneratedContent) async throws -> String {
        let cmd = try arguments.value(String.self, forProperty: "command")
        willRun()
        print("\n\u{1B}[33m$ \(cmd)\u{1B}[0m")
        guard approve("Run this command?") else { return "The user declined to run this command. Do not run it again; answer without it." }
        let (out, status) = runShell(cmd)
        print("\u{1B}[2m\(truncated(out))\u{1B}[0m(exit \(status))")
        return "exit code: \(status)\n\(truncated(out))"
    }
}
