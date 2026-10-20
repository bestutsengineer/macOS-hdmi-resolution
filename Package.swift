// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hdmi-resolution",
    platforms: [.macOS(.v13)],
    targets: [
        // The rules, config, state and menu model. No display API in here, so
        // the test suite can run all of it against a simulated display backend.
        .target(name: "HDMIResolutionCore"),
        // The menu bar app and the Quartz backend that talks to real displays.
        .executableTarget(name: "hdmi-resolution", dependencies: ["HDMIResolutionCore"]),
        .testTarget(
            name: "HDMIResolutionCoreTests",
            dependencies: ["HDMIResolutionCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
