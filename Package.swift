// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MixTake",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "MixTake", targets: ["MixTake"])
    ],
    targets: [
        .executableTarget(
            name: "MixTake",
            path: "Sources/MixTake"
        ),
        .testTarget(
            name: "MixTakeTests",
            dependencies: ["MixTake"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
