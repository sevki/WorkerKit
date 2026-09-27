// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "WorkersSwift",
    platforms: [.macOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "WorkersSwift",
            targets: ["WorkersSwift"]
        ),
        // An example worker; `swift package worker-build` links it into WorkersSwift.wasm.
        .executable(
            name: "WorkersSwiftWasm",
            targets: ["WorkersSwiftWasm"]
        ),
        .plugin(
            name: "WorkerBuild",
            targets: ["WorkerBuild"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
        // The Swift counterpart of wasm-bindgen and js-sys.
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.59.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .macro(
            name: "WorkersSwiftMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "WorkersSwift",
            dependencies: [
                "WorkersSwiftMacros",
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ]
        ),
        // The example worker; WorkersSwiftWasm links it into WorkersSwift.wasm.
        .target(
            name: "HelloWorker",
            dependencies: [
                "WorkersSwift",
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ]
        ),
        .executableTarget(
            name: "WorkersSwiftWasm",
            dependencies: ["HelloWorker"]
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
        .testTarget(
            name: "WorkersSwiftMacrosTests",
            dependencies: [
                "WorkersSwiftMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
