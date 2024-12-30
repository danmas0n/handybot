// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "HandyBot",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "HandyBot",
            type: .dynamic,
            targets: ["HandyBot"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "HandyBot",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "HandyBotTests",
            dependencies: ["HandyBot"]
        )
    ]
)
