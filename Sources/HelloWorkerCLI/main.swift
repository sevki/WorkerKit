import Foundation
import HelloWorkerActors
import WorkerKitDistributed

// A native CLI that calls HelloWorker's Doubler distributed actor exactly
// the way another worker would (`try await doubler.double(n)`) — the same
// WorkersActorSystem type, whose native build talks WebSocket/JSON instead
// of Workers RPC. Run it against a worker started
// by `npm run test:e2e`-style harness, or `wrangler dev`/`celld dev`:
//
//     swift run HelloWorkerCLI http://127.0.0.1:8787 double 21
//     swift run HelloWorkerCLI http://127.0.0.1:8787 echo "hello from the CLI"

let arguments = CommandLine.arguments
guard arguments.count >= 3, let worker = URL(string: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: HelloWorkerCLI <worker-url> double <n> | echo <text>\n".utf8))
    exit(64)
}

let system = WorkersActorSystem(worker: worker)

do {
    let doubler = try Doubler.resolve(id: "doubler", using: system)
    switch arguments[2] {
    case "double":
        guard arguments.count > 3, let n = Int(arguments[3]) else {
            FileHandle.standardError.write(Data("usage: HelloWorkerCLI <worker-url> double <n>\n".utf8))
            exit(64)
        }
        print(try await doubler.double(n))

    case "echo":
        guard arguments.count > 3 else {
            FileHandle.standardError.write(Data("usage: HelloWorkerCLI <worker-url> echo <text>\n".utf8))
            exit(64)
        }
        print(try await doubler.echo(arguments[3]))

    default:
        FileHandle.standardError.write(Data("unknown command \(arguments[2]); expected double or echo\n".utf8))
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    system.close()
    await system.wait()
    exit(1)
}

system.close()
await system.wait()
