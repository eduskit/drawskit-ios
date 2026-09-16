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
            url: "https://sdk.eduskit.com/drawskit/ios/0.1.3/binary.zip",
            checksum: "a48751523f2cbc59b6636e8da56970e8b53ac825790a9280127bd0d6f0cad516"
        ),
        .target(
            name: "DrawsKit",
            dependencies: ["WhiteboardFFI"],
            path: "Sources/DrawsKit",
            resources: [.process("Resources")]
        ),
    ]
)
