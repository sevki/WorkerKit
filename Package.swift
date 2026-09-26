// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WorkersSwift",
    // `Synchronization.Mutex` guards the ABI state in native test runs.
    platforms: [.macOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "WorkersSwift",
            targets: ["WorkersSwift"]
        ),
        // The module that `swift package worker-build` links into WorkersSwift.wasm.
        .executable(
            name: "WorkersSwiftWasm",
            targets: ["WorkersSwiftWasm"]
        ),
        .plugin(
            name: "WorkerBuild",
            targets: ["WorkerBuild"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "WorkersSwift"
        ),
        .executableTarget(
            name: "WorkersSwiftWasm",
            dependencies: ["WorkersSwift"]
        ),
        .plugin(
            name: "WorkerBuild",
            capability: .command(
                intent: .custom(
                    verb: "worker-build",
                    description: "Build a Swift worker to WebAssembly with the workerd/celld JavaScript shim"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Writes the built worker to build/worker"),
                ]
            )
        ),
        .testTarget(
            name: "WorkersSwiftTests",
            dependencies: ["WorkersSwift"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
