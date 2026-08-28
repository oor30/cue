// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Cue",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "CueCore",
            targets: ["CueCore"]
        ),
        .executable(
            name: "Cue",
            targets: ["CueApp"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.6"
        )
    ],
    targets: [
        .target(
            name: "CueCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "CueApp",
            dependencies: [
                "CueCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("Vision"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CueCoreTests",
            dependencies: ["CueCore"]
        ),
        .testTarget(
            name: "CueAppTests",
            dependencies: ["CueApp"]
        )
    ],
    swiftLanguageModes: [.v6]
)
