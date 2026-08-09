// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RTT",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "RTT",
            dependencies: [],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "RTTTests",
            dependencies: ["RTT"]
        ),
    ]
)
