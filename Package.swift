// swift-tools-version:4.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Sift",
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "0.3.0"),
        .package(url: "https://github.com/onevcat/Rainbow", from: "3.1.5"),
        .package(url: "https://github.com/jakeheis/Shout", from: "0.5.6"),
        .package(url: "https://github.com/tuist/shell.git", .upToNextMajor(from: "2.2.0")),
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
                           "Shell",
                           "SwiftyJSON"]),
        .testTarget(
            name: "SiftTests",
            dependencies: ["SiftLib"]),
    ]
)
