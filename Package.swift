// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fire",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "FireKit",
            path: "Sources/FireKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Fire",
            dependencies: ["FireKit"],
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
