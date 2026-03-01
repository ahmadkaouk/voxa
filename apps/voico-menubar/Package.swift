// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "voico-menubar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "voico-menubar", targets: ["VoicoMenuBar"]),
    ],
    targets: [
        .executableTarget(
            name: "VoicoMenuBar",
            path: "Sources/VoicoMenuBar"
        ),
        .testTarget(
            name: "VoicoMenuBarTests",
            dependencies: ["VoicoMenuBar"],
            path: "Tests/VoicoMenuBarTests"
        ),
    ]
)
