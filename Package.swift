// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
        .package(url: "https://github.com/onevcat/Rainbow", from: "3.1.5"),
        .package(url: "https://github.com/IBM-Swift/BlueSocket", from: "1.0.46"),
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", from: "5.0.0"),
        .package(url: "https://github.com/JohnSundell/CollectionConcurrencyKit.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Sift",
            dependencies: ["SiftLib"]),
        .target(
            name: "SiftLib",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser"),
                           "Rainbow",
                           "SwiftyJSON",
                           "CollectionConcurrencyKit",
                           "Shout"]),
        .target(
            name: "Shout",
            dependencies: ["CSSH", .product(name: "Socket", package: "BlueSocket")]),
        .binaryTarget(name: "CSSH", path: "CSSH.xcframework"),
    ]
)
