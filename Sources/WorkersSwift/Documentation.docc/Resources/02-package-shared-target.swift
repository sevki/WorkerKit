// swift-tools-version: 6.3
// Package.swift

import PackageDescription

let package = Package(
    name: "GreeterExample",
    products: [
        .library(name: "GreeterKit", targets: ["GreeterKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sevki/workers-swift.git", from: "1.0.0"),
    ],
    targets: [
        // The distributed actor declaration, shared by the worker and the CLI.
        .target(
            name: "GreeterKit",
            dependencies: [.product(name: "WorkersDistributed", package: "workers-swift")]
        ),
    ]
)
