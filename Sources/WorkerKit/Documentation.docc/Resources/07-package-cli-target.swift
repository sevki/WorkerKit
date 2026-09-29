// swift-tools-version: 6.3
// Package.swift

import PackageDescription

let package = Package(
    name: "GreeterExample",
    products: [
        .library(name: "GreeterKit", targets: ["GreeterKit"]),
        .executable(name: "GreeterWorkerWasm", targets: ["GreeterWorkerWasm"]),
        .executable(name: "GreeterCLI", targets: ["GreeterCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sevki/WorkerKit.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "GreeterKit",
            dependencies: [.product(name: "WorkerKitDistributed", package: "WorkerKit")]
        ),
        .target(
            name: "GreeterWorker",
            dependencies: [
                "GreeterKit",
                .product(name: "WorkerKit", package: "WorkerKit"),
                .product(name: "WorkerKitDistributed", package: "WorkerKit"),
            ]
        ),
        .executableTarget(
            name: "GreeterWorkerWasm",
            dependencies: [.target(name: "GreeterWorker", condition: .when(platforms: [.wasi]))]
        ),
        // A native command-line tool: calls Greeter the same way the
        // worker does, over WorkerKitDistributed's native WebSocket
        // transport instead of Workers RPC.
        .executableTarget(
            name: "GreeterCLI",
            dependencies: ["GreeterKit", .product(name: "WorkerKitDistributed", package: "WorkerKit")]
        ),
    ]
)
