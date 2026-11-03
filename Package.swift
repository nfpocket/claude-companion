// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeCompanion",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeCompanion", targets: ["ClaudeCompanion"]),
        // What agents call to put checks and ideas on the menu: see Sources/MenuCLI.
        .executable(name: "menu", targets: ["MenuCLI"]),
    ],
    targets: [
        // Task Tracker (merged in from github.com/nfpocket/task-tracker): data, menu, and its menu bar UI.
        .target(name: "TaskTrackerCore"),
        .target(name: "TaskTrackerUI", dependencies: ["TaskTrackerCore"]),
        .executableTarget(name: "MenuCLI", dependencies: ["TaskTrackerCore"]),
        .executableTarget(
            name: "ClaudeCompanion",
            dependencies: ["TaskTrackerCore", "TaskTrackerUI"],
            path: "Sources/ClaudeCompanion",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(name: "TaskTrackerCoreTests", dependencies: ["TaskTrackerCore"]),
        .testTarget(name: "TaskTrackerUITests", dependencies: ["TaskTrackerUI", "TaskTrackerCore"]),
    ]
)
