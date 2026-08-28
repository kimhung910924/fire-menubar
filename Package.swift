// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fire",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 자동 업데이트. 없으면 고쳐도 사용자가 안 받는다.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        .target(
            name: "FireKit",
            path: "Sources/FireKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Fire",
            dependencies: ["FireKit", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Fire",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FireKitTests",
            dependencies: ["FireKit"],
            path: "Tests/FireKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
