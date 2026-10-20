import Foundation

/// A `/` command, as the input box's command menu shows it.
public struct SlashCommand: Sendable {
    public let name: String
    public let argument: String?  // shown after the name; Enter in the menu then waits for it instead of running
    public let about: String
}

public let slashCommands = [
    SlashCommand(name: "/cd", argument: "<folder>", about: "move the working folder (alone: home)"),
    SlashCommand(name: "/clear", argument: nil, about: "clear the screen and start a new conversation"),
    SlashCommand(name: "/explain-last", argument: nil, about: "ask the model about your last !command"),
    SlashCommand(name: "/fix-last", argument: nil, about: "ask the model to fix what your last !command hit"),
    SlashCommand(name: "/resume", argument: "<number>", about: "continue a saved conversation"),
    SlashCommand(name: "/sessions", argument: nil, about: "list saved conversations (/sessions delete <number>)"),
    SlashCommand(name: "/undo", argument: nil, about: "revert the latest file change"),
]

/// The commands starting with what was typed (including its `/`), in menu order.
public func slashCompletions(for typed: String) -> [SlashCommand] {
    slashCommands.filter { $0.name.hasPrefix(typed.lowercased()) }
}
