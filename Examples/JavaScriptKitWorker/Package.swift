// swift-tools-version: 6.3

import PackageDescription

// A step toward a faithful workers-rs port: the worker handles the runtime's
// own JavaScript Request/Response objects through JavaScriptKit (the Swift
// counterpart of wasm-bindgen/js-sys) instead of a hand-rolled byte ABI.
let package = Package(
    name: "JavaScriptKitWorker",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.59.0"),
    ],
    targets: [
        .executableTarget(
            name: "JSKitWorker",
            dependencies: [
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
