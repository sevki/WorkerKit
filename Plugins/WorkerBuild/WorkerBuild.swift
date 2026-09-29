import Foundation
import PackagePlugin

/// `swift package --allow-writing-to-package-directory worker-build`
///
/// The Swift counterpart of workers-rs' `worker-build`: cross-compiles an
/// executable product to a WASI reactor module with a Swift WebAssembly SDK
/// and writes it next to the JavaScript entry point (JavaScriptKit's
/// runtime.mjs followed by WorkerKit's shim.mjs), ready for wrangler,
/// workerd or celld:
///
///     build/worker/worker.mjs
///     build/worker/WorkerKit.wasm
///
/// Options:
///   --swift-sdk <id>        Swift SDK to build with (default: the installed
///                           `*_wasm` SDK)
///   --product <name>        executable product to build (default:
///                           WorkerKitWasm, else the only executable)
///   -c, --configuration     debug or release (default: release)
///   --output <dir>          output directory (default: build/worker)
@main
struct WorkerBuild: CommandPlugin {
    static let shimPath = "JavaScript/shim.mjs"
    static let runtimePath = "Plugins/PackageToJS/Templates/runtime.mjs"
    static let wasmName = "WorkerKit.wasm"

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
        let shim = try file(Self.shimPath, inPackageWithProduct: "WorkerKit", from: context.package)
        let runtime = try file(Self.runtimePath, inPackageWithProduct: "JavaScriptKit", from: context.package)
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

        print("worker-build: building \(product) with Swift SDK \(sdk) (\(configuration))")
        try run(swift, buildArguments)
        let binPath = try run(swift, buildArguments + ["--show-bin-path"], captureOutput: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wasm = URL(fileURLWithPath: binPath).appending(path: "\(product).wasm")

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let wasmDestination = outputDirectory.appending(path: Self.wasmName)
        if fileManager.fileExists(atPath: wasmDestination.path()) {
            try fileManager.removeItem(at: wasmDestination)
        }
        try fileManager.copyItem(at: wasm, to: wasmDestination)
        let exports = try wasmExportNames(Array(Data(contentsOf: wasm)))
        let durableObjects = try durableObjectExports(exports)
        let rpcFunctions = try rpcExports(exports)
        try (bundle(runtime: runtime, shim: shim) + entryPoints(rpcFunctions: rpcFunctions, durableObjects: durableObjects))
            .write(to: outputDirectory.appending(path: "worker.mjs"), atomically: true, encoding: .utf8)
        if !rpcFunctions.isEmpty {
            print("worker-build: WorkerEntrypoint RPC: \(rpcFunctions.joined(separator: ", "))")
        }
        for (name, methods) in durableObjects {
            print("worker-build: Durable Object \(name)\(methods.isEmpty ? "" : " (RPC: \(methods.joined(separator: ", ")))")")
        }

        print("worker-build: wrote \(outputDirectory.appending(path: "worker.mjs").path()) and \(Self.wasmName)")
    }

    private func swiftExecutable(_ context: PluginContext) throws -> URL {
        if let tool = try? context.tool(named: "swift") {
            return tool.url
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    /// The installed `*_wasm` SDK built for the active toolchain. An SDK only
    /// works with the compiler it was built for, and `swift sdk list` does not
    /// say which one that is, so match its id to the toolchain's tag in
    /// `swift --version`, such as `swift-6.3-RELEASE`.
    private func defaultWasmSDK(swift: URL) throws -> String {
        let sdks = try run(swift, ["sdk", "list"], captureOutput: true)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix("_wasm") }
        let version = (try? run(swift, ["--version"], captureOutput: true, includeStandardError: true)) ?? ""
        return try Self.wasmSDK(from: sdks, swiftVersion: version)
    }

    static func wasmSDK(from sdks: [String], swiftVersion: String) throws -> String {
        let tags = swiftVersion
            .split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" })
            .map(String.init)
            .filter { $0.hasPrefix("swift-") }
        if let sdk = tags.lazy.map({ "\($0)_wasm" }).first(where: { sdks.contains($0) }) {
            return sdk
        }
        if sdks.count == 1 {
            return sdks[0]
        }
        if sdks.isEmpty {
            throw WorkerBuildError(
                "no Swift WebAssembly SDK is installed; install the one that matches `swift --version` (see https://www.swift.org/documentation/articles/wasm-getting-started.html) or pass --swift-sdk"
            )
        }
        throw WorkerBuildError(
            "none of the installed Swift WebAssembly SDKs (\(sdks.joined(separator: ", "))) matches `swift --version`; pass --swift-sdk"
        )
    }

    private func defaultProduct(in package: Package) throws -> String {
        let executables = package.products.filter { $0 is ExecutableProduct }.map(\.name)
        if executables.contains("WorkerKitWasm") {
            return "WorkerKitWasm"
        }
        guard executables.count == 1, let product = executables.first else {
            throw WorkerBuildError("pass --product to pick one of the executable products: \(executables.joined(separator: ", "))")
        }
        return product
    }

    /// Finds `path` in the package that vends `product`: the package being
    /// built or one of its dependencies.
    private func file(_ path: String, inPackageWithProduct product: String, from package: Package) throws -> URL {
        var pending = [package]
        var visited = Set<String>()
        while let candidate = pending.popLast() {
            guard visited.insert(candidate.id).inserted else {
                continue
            }
            if candidate.products.contains(where: { $0.name == product }) {
                let file = candidate.directoryURL.appending(path: path)
                if FileManager.default.fileExists(atPath: file.path()) {
                    return file
                }
            }
            pending.append(contentsOf: candidate.dependencies.map(\.package))
        }
        throw WorkerBuildError("could not find \(path) in the \(product) package")
    }

    /// One ES module: runtime.mjs without its `export { SwiftRuntime };`,
    /// followed by the shim, which uses SwiftRuntime and imports the Wasm.
    private func bundle(runtime: URL, shim: URL) throws -> String {
        let runtimeSource = try String(contentsOf: runtime, encoding: .utf8)
        let exportLine = "export { SwiftRuntime };"
        guard let range = runtimeSource.range(of: exportLine, options: .backwards) else {
            throw WorkerBuildError("\(runtime.path()) no longer ends with \"\(exportLine)\"")
        }
        var bundled = runtimeSource
        bundled.removeSubrange(range)
        return bundled + "\n" + (try String(contentsOf: shim, encoding: .utf8))
    }

    /// The `@DurableObject` classes and their `@RPC` methods, from the
    /// `workers_do:<Class>[:<method>,<method>…]` exports of the module.
    private func durableObjectExports(_ exports: [String]) throws -> [(name: String, methods: [String])] {
        try exports
            .filter { $0.hasPrefix("workers_do:") }
            .map { export in
                let parts = export.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                let methods = parts.count > 2 ? parts[2].split(separator: ",").map(String.init) : []
                try checkIdentifiers([parts[1]] + methods, in: export)
                return (name: parts[1], methods: methods)
            }
    }

    /// The top-level `@RPC` functions, from the `workers_rpc:<name>` exports.
    private func rpcExports(_ exports: [String]) throws -> [String] {
        try exports
            .filter { $0.hasPrefix("workers_rpc:") }
            .map { export in
                let name = String(export.dropFirst("workers_rpc:".count))
                try checkIdentifiers([name], in: export)
                return name
            }
    }

    /// The macros check these names too; the generated JavaScript must not be
    /// able to break on them.
    private func checkIdentifiers(_ identifiers: [String], in export: String) throws {
        for identifier in identifiers where identifier.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) == nil {
            throw WorkerBuildError("export \(export) has a name that is not a JavaScript identifier")
        }
    }

    /// The module's default export and its Durable Object classes. The runtime
    /// finds RPC methods on class prototypes, so a worker with top-level
    /// `@RPC` functions gets a `WorkerEntrypoint` class, each Durable Object
    /// a `DurableObject` class; every method forwards to Swift.
    private func entryPoints(rpcFunctions: [String], durableObjects: [(name: String, methods: [String])]) -> String {
        var imports: [String] = []
        if !rpcFunctions.isEmpty {
            imports.append("WorkerEntrypoint as __WorkerKitWorkerEntrypoint")
        }
        if !durableObjects.isEmpty {
            imports.append("DurableObject as __WorkerKitDurableObjectBase")
        }

        var source = "\n"
        if !imports.isEmpty {
            source += "import { \(imports.joined(separator: ", ")) } from \"cloudflare:workers\";\n"
        }

        if rpcFunctions.isEmpty {
            source += "\nexport default { fetch: __workerKitFetch };\n"
        } else {
            source += """

                export default class extends __WorkerKitWorkerEntrypoint {
                  async fetch(request) {
                    return __workerKitFetch(request, this.env, this.ctx);
                  }

                """
            for name in rpcFunctions {
                source += """

                      async \(name)(...args) {
                        return __workerKitRPC("\(name)", args);
                      }

                    """
            }
            source += "}\n"
        }

        // Each class is bound to a prefixed constant and exported under its
        // own name, so a Durable Object named like a binding of the bundled
        // runtime or shim (`SwiftRuntime`, `ConsoleStream`, …) cannot
        // redeclare it.
        for (name, methods) in durableObjects {
            let binding = "__workerKitDurableObjectClass_\(name)"
            source += """

                const \(binding) = class extends __WorkerKitDurableObjectBase {
                  #swift;

                  constructor(ctx, env) {
                    super(ctx, env);
                    this.#swift = __workerKitDurableObject("\(name)", ctx, env);
                    this.#swift.catch(() => {});
                  }

                  async fetch(request) {
                    return (await this.#swift).fetch(request);
                  }

                  async alarm() {
                    return (await this.#swift).alarm();
                  }

                  async webSocketMessage(ws, message) {
                    return (await this.#swift).webSocketMessage(ws, message);
                  }

                  async webSocketClose(ws, code, reason, wasClean) {
                    return (await this.#swift).webSocketClose(ws, code, reason, wasClean);
                  }

                  async webSocketError(ws, error) {
                    return (await this.#swift).webSocketError(ws, error);
                  }

                """
            for method in methods {
                source += """

                      async \(method)(...args) {
                        return (await this.#swift).rpc("\(method)", args);
                      }

                    """
            }
            source += """
                };
                Object.defineProperty(\(binding), "name", { value: "\(name)" });
                export { \(binding) as \(name) };

                """
        }
        return source
    }

    /// The export names of a WebAssembly module (section 7 of the binary format).
    private func wasmExportNames(_ bytes: [UInt8]) throws -> [String] {
        var offset = 8
        guard bytes.count >= offset, bytes[0..<4] == [0x00, 0x61, 0x73, 0x6D] else {
            throw WorkerBuildError("the built module is not WebAssembly")
        }

        func leb128() throws -> Int {
            var result = 0
            var shift = 0
            while true {
                guard offset < bytes.count, shift < 35 else {
                    throw WorkerBuildError("malformed WebAssembly module")
                }
                let byte = bytes[offset]
                offset += 1
                result |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    return result
                }
                shift += 7
            }
        }

        while offset < bytes.count {
            let sectionID = bytes[offset]
            offset += 1
            let size = try leb128()
            let end = offset + size
            guard end <= bytes.count else {
                throw WorkerBuildError("malformed WebAssembly module")
            }
            guard sectionID == 7 else {
                offset = end
                continue
            }

            var names: [String] = []
            for _ in 0..<(try leb128()) {
                let length = try leb128()
                guard offset + length <= end else {
                    throw WorkerBuildError("malformed WebAssembly export section")
                }
                names.append(String(decoding: bytes[offset..<(offset + length)], as: UTF8.self))
                offset += length + 1 // the name, then the export kind
                _ = try leb128() // the export index
            }
            return names
        }
        return []
    }

    @discardableResult
    private func run(
        _ executable: URL,
        _ arguments: [String],
        captureOutput: Bool = false,
        includeStandardError: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = executable.lastPathComponent == "env" ? ["swift"] + arguments : arguments
        let pipe = Pipe()
        if captureOutput {
            process.standardOutput = pipe
            if includeStandardError {
                process.standardError = pipe
            }
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
