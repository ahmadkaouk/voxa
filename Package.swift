// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "voxa",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "voxa", targets: ["Voxa"]),
    ],
    targets: [
        .executableTarget(
            name: "Voxa",
            resources: [.copy("Resources/Sounds")]
        ),
        .testTarget(
            name: "VoxaTests",
            dependencies: ["Voxa"]
        ),
    ]
)
