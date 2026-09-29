import Foundation
import GreeterKit
import WorkerKitDistributed

// swift run GreeterCLI https://greeter-worker.example.workers.dev world

let arguments = CommandLine.arguments
guard arguments.count > 2, let worker = URL(string: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: GreeterCLI <worker-url> <name>\n".utf8))
    exit(64)
}

let system = WorkersActorSystem(worker: worker)

do {
    // The id passed here is never interpreted for a singleton-hosted
    // actor like this one — WorkersActorSystem.host(_:) always dispatches
    // to the one hosted instance, whatever id a caller used.
    let greeter = try Greeter.resolve(id: "greeter", using: system)
    print(try await greeter.hello(arguments[2]))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    system.close()
    await system.wait()
    exit(1)
}

system.close()
await system.wait()
