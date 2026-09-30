// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "WorkerKit",
    platforms: [.macOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "WorkerKit",
            targets: ["WorkerKit"]
        ),
        // `WorkersActorSystem`: one type for distributed actors, backed by
        // Workers RPC inside a worker and by a WebSocket everywhere else.
        .library(
            name: "WorkerKitDistributed",
            targets: ["WorkerKitDistributed"]
        ),
        // An example worker; `swift package worker-build` links it into WorkerKit.wasm.
        .executable(
            name: "WorkerKitWasm",
            targets: ["WorkerKitWasm"]
        ),
        // A native CLI that calls HelloWorker's Doubler distributed actor
        // over plain WebSocket/JSON — run it with `swift run HelloWorkerCLI
        // <ws-url>`, once the worker is serving.
        .executable(
            name: "HelloWorkerCLI",
            targets: ["HelloWorkerCLI"]
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
        // `swift package generate-documentation` / `swift package --disable-sandbox preview-documentation`.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.0"),
        // WorkerKitDistributed's native transport: a real RFC 6455 client
        // that works on Linux, unlike swift-corelibs-foundation's
        // URLSessionWebSocketTask (libcurl-backed there, and libcurl has no
        // WebSocket support at all).
        .package(url: "https://github.com/hummingbird-project/swift-websocket.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // The unix-socket transport talks to a local process with plain NIO;
        // swift-websocket already brings it in, this names it.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .macro(
            name: "WorkerKitMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "WorkerKit",
            dependencies: [
                "WorkerKitMacros",
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
                .product(name: "JavaScriptBigIntSupport", package: "JavaScriptKit"),
            ]
        ),
        // The one place the platform matters: each dependency is only needed
        // by the transport for its own platform.
        .target(
            name: "WorkerKitDistributed",
            dependencies: [
                .target(name: "WorkerKit", condition: .when(platforms: [.wasi])),
                .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
                .product(name: "WSClient", package: "swift-websocket", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "Logging", package: "swift-log", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.macOS, .linux])),
            ]
        ),
        // The distributed actors HelloWorker hosts and HelloWorkerCLI calls.
        .target(
            name: "HelloWorkerActors",
            dependencies: ["WorkerKitDistributed"]
        ),
        // The example worker; WorkerKitWasm links it into WorkerKit.wasm.
        .target(
            name: "HelloWorker",
            dependencies: [
                "WorkerKit",
                "WorkerKitDistributed",
                "HelloWorkerActors",
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ]
        ),
        // A worker only runs as wasm, so the host build leaves it out.
        .executableTarget(
            name: "WorkerKitWasm",
            dependencies: [.target(name: "HelloWorker", condition: .when(platforms: [.wasi]))]
        ),
        .executableTarget(
            name: "HelloWorkerCLI",
            dependencies: ["HelloWorkerActors", "WorkerKitDistributed"]
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
            name: "WorkerKitTests",
            dependencies: ["WorkerKit"]
        ),
        // The native client's transports: only they exist off the worker.
        .testTarget(
            name: "WorkerKitDistributedTests",
            dependencies: [
                .target(name: "WorkerKitDistributed", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.macOS, .linux])),
            ]
        ),
        .testTarget(
            name: "WorkerKitMacrosTests",
            dependencies: [
                "WorkerKitMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
