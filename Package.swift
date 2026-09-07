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
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.5"),
    ],
    targets: [
        .executableTarget(
            name: "VoxaMenuBar",
            dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")],
            resources: [.copy("Resources/Sounds"), .copy("Resources/ThirdPartyNotices.txt")]
        ),
        .testTarget(
            name: "VoxaMenuBarTests",
            dependencies: ["VoxaMenuBar"]
        ),
    ]
)
