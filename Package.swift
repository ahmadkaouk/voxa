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
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.5"),
    ],
    targets: [
        .executableTarget(
            name: "Voxa",
            dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")],
            resources: [.copy("Resources/Sounds"), .copy("Resources/ThirdPartyNotices.txt")]
        ),
        .testTarget(
            name: "VoxaTests",
            dependencies: ["Voxa"]
        ),
    ]
)
