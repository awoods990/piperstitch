// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StitchPilot",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "StitchPilotCore", targets: ["StitchPilotCore"]),
        .executable(name: "StitchPilot", targets: ["StitchPilotApp"]),
        .executable(name: "DigitizeCLI", targets: ["DigitizeCLI"]),
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
        // A no-GUI command-line harness around the exact same digitizing
        // pipeline the app uses: import -> classify -> flatten -> render to
        // PNG + print an Embroidery Readiness report. Exists so digitizing
        // quality can actually be inspected and iterated on directly (real
        // stitch renders, real scores) without needing to drive the native
        // UI, which this environment has no accessibility permission to
        // script — see DIGITIZING_ENGINE.md.
        .executableTarget(
            name: "DigitizeCLI",
            dependencies: ["StitchPilotCore"],
            path: "Sources/DigitizeCLI"
        ),
        .testTarget(
            name: "StitchPilotCoreTests",
            dependencies: ["StitchPilotCore"],
            path: "Tests/StitchPilotCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
