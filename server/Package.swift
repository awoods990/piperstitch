// swift-tools-version:5.9
import PackageDescription

// The web edition's HTTP API: a thin Vapor wrapper around the very same
// StitchPilotCore the Mac app uses, depended on by path so the root
// package (and the Mac app inside it) is never modified for the web's
// sake. Everything in here is stateless -- the browser holds the
// document and sends it back to be re-flattened -- so the server scales
// by just running more of it. Built for Linux in Docker (see Dockerfile)
// and runnable on macOS for development.
let package = Package(
    name: "StitchPilotServer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "StitchPilot", path: ".."),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.100.0"),
    ],
    targets: [
        .executableTarget(
            name: "StitchPilotServer",
            dependencies: [
                .product(name: "StitchPilotCore", package: "StitchPilot"),
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/StitchPilotServer"
        ),
    ]
)
