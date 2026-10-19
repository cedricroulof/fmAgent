// swift-tools-version: 6.2
import Foundation
import PackageDescription

// shortcut: with only the Command Line Tools, the build system doesn't always pass Swift Testing's macro plugin
// path, so `swift test` fails with "plugin for module 'TestingMacros' not found". Drop this once that's fixed.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] =
    FileManager.default.fileExists(atPath: testingPlugins) && !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
    ? [.unsafeFlags(["-plugin-path", testingPlugins])] : []

let package = Package(
    name: "fmagent",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "FMAgentCore"),
        .executableTarget(name: "fmagent", dependencies: ["FMAgentCore"]),
        .testTarget(name: "FMAgentCoreTests", dependencies: ["FMAgentCore"], swiftSettings: testSettings),
    ]
)
