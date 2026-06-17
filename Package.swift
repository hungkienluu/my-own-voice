// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyOwnVoice",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MyOwnVoiceApp", targets: ["MyOwnVoiceApp"]),
        .executable(name: "AppCoreSelfChecks", targets: ["AppCoreSelfChecks"]),
        .executable(name: "FocusedInsertionProbe", targets: ["FocusedInsertionProbe"]),
        .executable(name: "LocalTranscriptionSmoke", targets: ["LocalTranscriptionSmoke"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "ModelRouting", targets: ["ModelRouting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", .upToNextMinor(from: "0.9.4")),
    ],
    targets: [
        .executableTarget(
            name: "MyOwnVoiceApp",
            dependencies: [
                "AppCore",
                "ModelRouting",
            ],
            path: "Sources/MyOwnVoiceApp"
        ),
        .target(
            name: "AppCore",
            dependencies: [
                "ModelRouting",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/AppCore"
        ),
        .target(
            name: "ModelRouting",
            path: "Sources/ModelRouting"
        ),
        .executableTarget(
            name: "AppCoreSelfChecks",
            dependencies: ["AppCore"],
            path: "Tests/AppCoreSelfChecks"
        ),
        .executableTarget(
            name: "FocusedInsertionProbe",
            dependencies: ["AppCore"],
            path: "Tests/FocusedInsertionProbe"
        ),
        .executableTarget(
            name: "LocalTranscriptionSmoke",
            dependencies: [
                "AppCore",
                "ModelRouting",
            ],
            path: "Tests/LocalTranscriptionSmoke"
        ),
    ]
)
