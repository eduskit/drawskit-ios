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
            url: "https://sdk.eduskit.com/drawskit/ios/0.2.1/binary.zip",
            checksum: "b5d1efa1c440092a60b8fecc7477fe5f94dfb40c7e539a9c6cfc19aa3951cadd"
        ),
        .target(
            name: "DrawsKit",
            dependencies: ["WhiteboardFFI"],
            path: "Sources/DrawsKit",
            resources: [.process("Resources")]
        ),
    ]
)
