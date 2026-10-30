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
            url: "https://sdk.eduskit.com/drawskit/ios/0.1.6/binary.zip",
            checksum: "dac691673f0fabcd57fa107c4eb8b9888774a0fe3e88de963043a96d2f0b9777"
        ),
        .target(
            name: "DrawsKit",
            dependencies: ["WhiteboardFFI"],
            path: "Sources/DrawsKit",
            resources: [.process("Resources")]
        ),
    ]
)
