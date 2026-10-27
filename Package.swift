// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MixTake",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MixTake", targets: ["MixTake"])
    ],
    targets: [
        .executableTarget(
            name: "MixTake",
            path: "Sources/MixTake"
        )
    ],
    swiftLanguageVersions: [.v5]
)
