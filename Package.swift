// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cue",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cue", targets: ["Cue"])
    ],
    targets: [
        .executableTarget(
            name: "Cue",
            path: "Sources/Cue",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation")
            ]
        ),
        .testTarget(
            name: "CueTests",
            dependencies: ["Cue"],
            path: "Tests/CueTests"
        )
    ]
)
