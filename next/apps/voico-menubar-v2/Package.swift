// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "voico-menubar-v2",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "voico-menubar-v2", targets: ["VoicoMenuBarV2"]),
    ],
    targets: [
        .executableTarget(
            name: "VoicoMenuBarV2",
            path: "Sources/VoicoMenuBarV2"
        ),
        .testTarget(
            name: "VoicoMenuBarV2Tests",
            dependencies: ["VoicoMenuBarV2"],
            path: "Tests/VoicoMenuBarV2Tests"
        ),
    ]
)
