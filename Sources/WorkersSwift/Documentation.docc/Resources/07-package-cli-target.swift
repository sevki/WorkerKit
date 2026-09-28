// Package.swift

let package = Package(
    name: "GreeterExample",
    products: [
        .library(name: "GreeterKit", targets: ["GreeterKit"]),
        .executable(name: "GreeterWorkerWasm", targets: ["GreeterWorkerWasm"]),
        .executable(name: "GreeterCLI", targets: ["GreeterCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sevki/workers-swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "GreeterKit",
            dependencies: [.product(name: "WorkersDistributed", package: "workers-swift")]
        ),
        .target(
            name: "GreeterWorker",
            dependencies: [
                "GreeterKit",
                .product(name: "WorkersSwift", package: "workers-swift"),
                .product(name: "WorkersDistributed", package: "workers-swift"),
            ]
        ),
        .executableTarget(
            name: "GreeterWorkerWasm",
            dependencies: [.target(name: "GreeterWorker", condition: .when(platforms: [.wasi]))]
        ),
        // A native command-line tool: calls Greeter the same way the
        // worker does, over WorkersDistributed's native WebSocket
        // transport instead of Workers RPC.
        .executableTarget(
            name: "GreeterCLI",
            dependencies: ["GreeterKit", .product(name: "WorkersDistributed", package: "workers-swift")]
        ),
    ]
)
