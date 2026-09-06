// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StitchPilot",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "StitchPilotCore", targets: ["StitchPilotCore"]),
        .executable(name: "StitchPilot", targets: ["StitchPilotApp"]),
    ],
    targets: [
        .target(
            name: "StitchPilotCore",
            path: "Sources/StitchPilotCore"
        ),
        .executableTarget(
            name: "StitchPilotApp",
            dependencies: ["StitchPilotCore"],
            path: "Sources/StitchPilotApp",
            resources: [.copy("Resources/OneClickStitchIcon.png")]
        ),
        .testTarget(
            name: "StitchPilotCoreTests",
            dependencies: ["StitchPilotCore"],
            path: "Tests/StitchPilotCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
