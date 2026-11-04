// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WindowManager",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "WindowManager",
            path: "Sources/WindowManager",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WindowManagerTests",
            dependencies: ["WindowManager"],
            path: "Tests/WindowManagerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
