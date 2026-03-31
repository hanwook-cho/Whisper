// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperCore",
    platforms: [.iOS("16.4")],
    products: [
        .library(name: "WhisperCore", targets: ["WhisperCore"]),
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "whisper",
            path: "Vendor/whisper.xcframework"
        ),
        .target(
            name: "WhisperCore",
            dependencies: ["whisper"],
            path: "Sources/WhisperCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(
            name: "WhisperCoreTests",
            dependencies: ["WhisperCore"],
            path: "Tests/WhisperCoreTests"
        ),
    ]
)
