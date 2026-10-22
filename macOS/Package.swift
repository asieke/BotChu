// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BotChu",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BotChuCore"),
        .executableTarget(name: "BotChu", dependencies: ["BotChuCore"]),
        // Runs real turns on an account from the command line (not shipped in the app).
        .executableTarget(name: "botchu-smoke", dependencies: ["BotChuCore"]),
        .testTarget(name: "BotChuCoreTests", dependencies: ["BotChuCore"]),
    ],
    swiftLanguageModes: [.v5]
)
