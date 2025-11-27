// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TranscribeCLI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TranscriptionCore", targets: ["TranscriptionCore"]),
        .executable(name: "TranscribeCLI", targets: ["TranscribeCLI"]),
        .executable(name: "FreeWhisperKey", targets: ["TranscribeMenuApp"])
    ],
    targets: [
        .target(
            name: "TranscriptionCore"
        ),
        .executableTarget(
            name: "TranscribeCLI",
            dependencies: ["TranscriptionCore"]
        ),
        .executableTarget(
            name: "TranscribeMenuApp",
            dependencies: ["TranscriptionCore"]
        ),
        .testTarget(
            name: "TranscriptionCoreTests",
            dependencies: ["TranscriptionCore"]
        ),
        .testTarget(
            name: "TranscribeMenuAppTests",
            dependencies: ["TranscribeMenuApp", "TranscriptionCore"]
        )
    ]
)
