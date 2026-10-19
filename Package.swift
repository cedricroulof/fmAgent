// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "fmagent",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "FMAgentCore"),
        .executableTarget(name: "fmagent", dependencies: ["FMAgentCore"], linkerSettings: [.linkedLibrary("edit")]),
        .testTarget(name: "FMAgentCoreTests", dependencies: ["FMAgentCore"]),
    ]
)
