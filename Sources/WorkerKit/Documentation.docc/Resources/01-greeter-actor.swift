import Distributed
import WorkerKitDistributed

/// A `distributed actor`, shared between the worker that hosts it and any
/// native process that calls it.
public distributed actor Greeter {
    public typealias ActorSystem = WorkersActorSystem

    public distributed func hello(_ name: String) -> String {
        "Hello, \(name)!"
    }
}
