// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [
        .macOS(.v10_14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "0.3.0"),
        .package(url: "https://github.com/onevcat/Rainbow", from: "3.1.5"),
        .package(url: "https://github.com/jakeheis/Shout", from: "0.5.7"),
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "Sift",
            dependencies: ["SiftLib"]),
        .target(
            name: "SiftLib",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser"),
                           "Rainbow",
                           "Shout",
                           "SwiftyJSON"]),
        .testTarget(
            name: "SiftTests",
            dependencies: ["SiftLib"]),
    ]
)
