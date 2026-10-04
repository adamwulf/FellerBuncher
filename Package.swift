// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FellerBuncher",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "FellerBuncher", targets: ["FellerBuncher"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
        .package(url: "https://github.com/adamwulf/Logfmt.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "FellerBuncher",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Logfmt", package: "Logfmt"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "FellerBuncherTests",
            dependencies: [
                "FellerBuncher",
                .product(name: "Logfmt", package: "Logfmt"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
