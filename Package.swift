// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RTT",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        // 应用内自动更新（spec D）：二进制 framework 由 build 脚本拷入 app bundle
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "RTT",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "RTTTests",
            dependencies: ["RTT"]
        ),
    ]
)
