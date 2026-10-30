// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DrawsKit",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        .library(name: "DrawsKit", targets: ["DrawsKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "WhiteboardFFI",
            url: "https://sdk.eduskit.com/drawskit/ios/0.1.7/binary.zip",
            checksum: "492e8e0f3c1a36249f6e8e9bee99398b333e87c431d68c743a22bd2a51b7f37e"
        ),
        .target(
            name: "DrawsKit",
            dependencies: ["WhiteboardFFI"],
            path: "Sources/DrawsKit",
            resources: [.process("Resources")]
        ),
    ]
)
