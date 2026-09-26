import Foundation
import PackagePlugin

/// `swift package --allow-writing-to-package-directory worker-build`
///
/// The Swift counterpart of workers-rs' `worker-build`: cross-compiles an
/// executable product to a WASI reactor module with a Swift WebAssembly SDK
/// and writes it next to the JavaScript shim, ready for wrangler, workerd or
/// celld:
///
///     build/worker/worker.mjs
///     build/worker/WorkersSwift.wasm
///
/// Options:
///   --swift-sdk <id>        Swift SDK to build with (default: the installed
///                           `*_wasm` SDK, else `*_wasm-embedded`)
///   --product <name>        executable product to build (default:
///                           WorkersSwiftWasm, else the only executable)
///   -c, --configuration     debug or release (default: release)
///   --output <dir>          output directory (default: build/worker)
@main
struct WorkerBuild: CommandPlugin {
    static let shimPath = "Examples/workerd-celld/worker.mjs"
    static let wasmName = "WorkersSwift.wasm"

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        // ArgumentExtractor only understands long options, so take the
        // short `-c <configuration>` out first.
        var arguments = arguments
        var shortConfiguration: String?
        if let index = arguments.firstIndex(of: "-c") {
            guard index + 1 < arguments.count else {
                throw WorkerBuildError("-c needs a configuration: debug or release")
            }
            shortConfiguration = arguments[index + 1]
            arguments.removeSubrange(index...(index + 1))
        }

        var extractor = ArgumentExtractor(arguments)
        let requestedSDK = extractor.extractOption(named: "swift-sdk").last
        let requestedProduct = extractor.extractOption(named: "product").last
        let configuration = extractor.extractOption(named: "configuration").last
            ?? shortConfiguration
            ?? "release"
        let requestedOutput = extractor.extractOption(named: "output").last
        if !extractor.remainingArguments.isEmpty {
            throw WorkerBuildError("unexpected arguments: \(extractor.remainingArguments.joined(separator: " "))")
        }
        guard ["debug", "release"].contains(configuration) else {
            throw WorkerBuildError("configuration must be debug or release, not \(configuration)")
        }

        let packageDirectory = context.package.directoryURL
        let swift = try swiftExecutable(context)
        let sdk = try requestedSDK ?? defaultWasmSDK(swift: swift)
        let product = try requestedProduct ?? defaultProduct(in: context.package)
        let shim = try shimURL(in: context.package)
        let outputDirectory = requestedOutput.map {
            URL(fileURLWithPath: $0, relativeTo: packageDirectory)
        } ?? packageDirectory.appending(path: "build/worker")

        // A separate scratch path keeps the nested build off the lock that
        // `swift package` holds on the package's own .build directory.
        let buildArguments = [
            "build",
            "--package-path", packageDirectory.path(),
            "--scratch-path", context.pluginWorkDirectoryURL.appending(path: "wasm").path(),
            "--swift-sdk", sdk,
            "--configuration", configuration,
            "--product", product,
            "-Xswiftc", "-Xclang-linker", "-Xswiftc", "-mexec-model=reactor",
        ]

        // Package.swift links Embedded Swift's Unicode tables when this is set.
        var environment = ProcessInfo.processInfo.environment
        if sdk.hasSuffix("-embedded") {
            environment["WORKERS_SWIFT_EMBEDDED"] = "1"
        }

        print("worker-build: building \(product) with Swift SDK \(sdk) (\(configuration))")
        try run(swift, buildArguments, environment: environment)
        let binPath = try run(swift, buildArguments + ["--show-bin-path"], environment: environment, captureOutput: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wasm = URL(fileURLWithPath: binPath).appending(path: "\(product).wasm")

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for (source, name) in [(wasm, Self.wasmName), (shim, "worker.mjs")] {
            let destination = outputDirectory.appending(path: name)
            if fileManager.fileExists(atPath: destination.path()) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }

        print("worker-build: wrote \(outputDirectory.appending(path: "worker.mjs").path()) and \(Self.wasmName)")
    }

    private func swiftExecutable(_ context: PluginContext) throws -> URL {
        if let tool = try? context.tool(named: "swift") {
            return tool.url
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private func defaultWasmSDK(swift: URL) throws -> String {
        let sdks = try run(swift, ["sdk", "list"], captureOutput: true)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let sdk = sdks.first(where: { $0.hasSuffix("_wasm") }) ?? sdks.first(where: { $0.hasSuffix("_wasm-embedded") }) {
            return sdk
        }
        throw WorkerBuildError(
            "no Swift WebAssembly SDK is installed; install one (see https://www.swift.org/documentation/articles/wasm-getting-started.html) or pass --swift-sdk"
        )
    }

    private func defaultProduct(in package: Package) throws -> String {
        let executables = package.products.filter { $0 is ExecutableProduct }.map(\.name)
        if executables.contains("WorkersSwiftWasm") {
            return "WorkersSwiftWasm"
        }
        guard executables.count == 1, let product = executables.first else {
            throw WorkerBuildError("pass --product to pick one of the executable products: \(executables.joined(separator: ", "))")
        }
        return product
    }

    /// The shim ships with the WorkersSwift package, which is either the
    /// package being built or one of its dependencies.
    private func shimURL(in package: Package) throws -> URL {
        var pending = [package]
        var visited = Set<String>()
        while let candidate = pending.popLast() {
            guard visited.insert(candidate.id).inserted else {
                continue
            }
            if candidate.products.contains(where: { $0.name == "WorkersSwift" }) {
                let shim = candidate.directoryURL.appending(path: Self.shimPath)
                if FileManager.default.fileExists(atPath: shim.path()) {
                    return shim
                }
            }
            pending.append(contentsOf: candidate.dependencies.map(\.package))
        }
        throw WorkerBuildError("could not find \(Self.shimPath) in the WorkersSwift package")
    }

    @discardableResult
    private func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        captureOutput: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        if let environment {
            process.environment = environment
        }
        process.arguments = executable.lastPathComponent == "env" ? ["swift"] + arguments : arguments
        let pipe = Pipe()
        if captureOutput {
            process.standardOutput = pipe
        }
        try process.run()
        let output = captureOutput ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WorkerBuildError("swift \(arguments.joined(separator: " ")) failed with exit code \(process.terminationStatus)")
        }
        return String(decoding: output, as: UTF8.self)
    }
}

struct WorkerBuildError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
