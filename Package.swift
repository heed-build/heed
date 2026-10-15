// swift-tools-version: 6.4
import Foundation
import PackageDescription

// GhosttyKit is built locally (`mise run ghostty`, needs Xcode + the Metal toolchain). Until it exists the app builds
// with a placeholder pane, so everything else can be worked on without it.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasGhostty = FileManager.default.fileExists(atPath: "\(root)/Vendor/GhosttyKit.xcframework/Info.plist")

var targets: [Target] = [
    .target(name: "HeedCore"),
    .executableTarget(name: "heed", dependencies: ["HeedCore"]),
    .testTarget(name: "HeedCoreTests", dependencies: ["HeedCore"]),
]
var appDependencies: [Target.Dependency] = ["HeedCore", .product(name: "Sparkle", package: "Sparkle")]
if hasGhostty {
    targets += [
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
        .target(
            name: "HeedTerminal",
            dependencies: ["GhosttyKit", "HeedCore"],
            linkerSettings: [
                .linkedFramework("Carbon"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"), .linkedLibrary("c++"),
            ]
        ),
    ]
    appDependencies.append("HeedTerminal")
}

targets.append(.executableTarget(
    name: "HeedApp",
    dependencies: appDependencies,
    swiftSettings: hasGhostty ? [.define("HEED_GHOSTTY")] : []
))

let package = Package(
    name: "Heed",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "HeedApp", targets: ["HeedApp"]),
        .executable(name: "heed", targets: ["heed"]),
    ],
    // The updater (MIT): checks heed's appcast, verifies each download's EdDSA signature, installs and relaunches.
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: targets
)
