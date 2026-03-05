// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "voxa-menubar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "voxa-menubar", targets: ["VoxaMenuBar"]),
    ],
    targets: [
        .executableTarget(
            name: "VoxaMenuBar",
            path: "Sources/VoxaMenuBar"
        ),
        .testTarget(
            name: "VoxaMenuBarTests",
            dependencies: ["VoxaMenuBar"],
            path: "Tests/VoxaMenuBarTests"
        ),
    ]
)
