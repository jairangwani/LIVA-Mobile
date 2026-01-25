// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LIVAAnimation",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "LIVAAnimation",
            targets: ["LIVAAnimation"]
        ),
    ],
    dependencies: [
        // Socket.IO client for Swift
        .package(url: "https://github.com/socketio/socket.io-client-swift.git", from: "16.0.0"),
    ],
    targets: [
        .target(
            name: "LIVAAnimation",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift"),
            ],
            path: "LIVAAnimation/Sources"
        ),
        .testTarget(
            name: "LIVAAnimationTests",
            dependencies: ["LIVAAnimation"],
            path: "Tests"
        ),
    ]
)
