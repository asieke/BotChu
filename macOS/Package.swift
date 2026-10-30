// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BotChu",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BotChuCore"),
        .executableTarget(name: "BotChu", dependencies: ["BotChuCore"], resources: [.copy("Resources/ChatRenderer")]),
        // Runs real turns on an account from the command line (not shipped in the app).
        .executableTarget(name: "botchu-smoke", dependencies: ["BotChuCore"]),
        // The Sail account's headless agent, shipped beside the app (`SailCommand`).
        .executableTarget(name: "botchu-sail", dependencies: ["BotChuCore"]),
        // Drives a release build of the app from outside through its critical journeys (README.md, Test; #323).
        .executableTarget(name: "botchu-journeys", dependencies: ["BotChuCore"]),
        .testTarget(name: "BotChuCoreTests", dependencies: ["BotChuCore"]),
        .testTarget(name: "BotChuRenderingTests", dependencies: ["BotChu"]),
    ],
    swiftLanguageModes: [.v5]
)
