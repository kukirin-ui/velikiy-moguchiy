// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AppleSpeechBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppleSpeechBridge", type: .static, targets: ["AppleSpeechBridge"]),
    ],
    targets: [
        .target(name: "AppleSpeechBridge"),
    ]
)
