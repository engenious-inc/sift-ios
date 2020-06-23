// swift-tools-version:4.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Sift",
    dependencies: [
        .package(url: "https://github.com/onevcat/Rainbow", from: "3.1.5"),
        .package(url: "https://github.com/nsomar/Guaka.git" ,from: "0.4.1"),
        .package(url: "https://github.com/jakeheis/Shout", from: "0.5.5"),
        .package(url: "https://github.com/tuist/shell.git", .upToNextMajor(from: "2.2.0")),
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "Sift",
            dependencies: ["SiftLib"]),
        .target(
            name: "SiftLib",
            dependencies: ["Rainbow", "Guaka", "Shout", "Shell", "SwiftyJSON"]),
        .testTarget(
            name: "SiftTests",
            dependencies: ["SiftLib"]),
    ]
)
