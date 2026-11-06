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
            url: "https://sdk.eduskit.com/drawskit/ios/0.2.0/binary.zip",
            checksum: "03cf268de28c375b5b7c3308438a839bbdae52b99f5faae467e80f275e1052a5"
        ),
        .target(
            name: "DrawsKit",
            dependencies: ["WhiteboardFFI"],
            path: "Sources/DrawsKit",
            resources: [.process("Resources")]
        ),
    ]
)
