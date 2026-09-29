// swift-tools-version: 6.3
// Package.swift

import PackageDescription

let package = Package(
    name: "GreeterExample",
    products: [
        .library(name: "GreeterKit", targets: ["GreeterKit"]),
        .executable(name: "GreeterWorkerWasm", targets: ["GreeterWorkerWasm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sevki/WorkerKit.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "GreeterKit",
            dependencies: [.product(name: "WorkerKitDistributed", package: "WorkerKit")]
        ),
        // The worker itself: hosts `Greeter` and answers HTTP requests.
        .target(
            name: "GreeterWorker",
            dependencies: [
                "GreeterKit",
                .product(name: "WorkerKit", package: "WorkerKit"),
                .product(name: "WorkerKitDistributed", package: "WorkerKit"),
            ]
        ),
        // A worker only runs as wasm, so the host build leaves it out.
        .executableTarget(
            name: "GreeterWorkerWasm",
            dependencies: [.target(name: "GreeterWorker", condition: .when(platforms: [.wasi]))]
        ),
    ]
)
