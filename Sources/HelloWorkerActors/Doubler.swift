import Distributed
import WorkersDistributed

/// A `distributed actor` HelloWorker hosts and HelloWorkerCLI calls. Both
/// compile this same declaration against the same `WorkersActorSystem`
/// type — only that system's transport differs between wasm32 and the host
/// — so both binaries mangle its distributed methods identically.
public distributed actor Doubler {
    public typealias ActorSystem = WorkersActorSystem

    public distributed func double(_ n: Int) -> Int {
        n * 2
    }

    /// A generic distributed func: exercises generic-substitution transport
    /// (recordGenericSubstitution/decodeGenericSubstitutions), not just
    /// plain arguments.
    public distributed func echo<T: Codable & Sendable>(_ value: T) -> T {
        value
    }

    /// 9007199254740993 (2^53 + 1) is not exactly representable as a
    /// Double, so this comes back rounded if the transport falls through to
    /// a Double-backed number anywhere along the way.
    public distributed func bigNumber(_ n: Int64) -> Int64 {
        n
    }

    /// The same lossless-Int64 path, nested inside a collection.
    public distributed func bigNumbers(_ values: [Int64]) -> [Int64] {
        values
    }

    /// Exercises `JSValueEncoder`'s superEncoder()/superEncoder(forKey:):
    /// `Dog` delegates `name` to `Animal`'s own Codable conformance.
    public distributed func identify(_ dog: Dog) -> String {
        "\(dog.name) is a \(dog.breed)"
    }
}

public class Animal: Codable, @unchecked Sendable {
    public let name: String
    private enum CodingKeys: String, CodingKey { case name }

    public init(name: String) {
        self.name = name
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
    }
}

public final class Dog: Animal, @unchecked Sendable {
    public let breed: String
    private enum CodingKeys: String, CodingKey { case breed }

    public init(name: String, breed: String) {
        self.breed = breed
        super.init(name: name)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        breed = try container.decode(String.self, forKey: .breed)
        try super.init(from: container.superDecoder())
    }

    public override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(breed, forKey: .breed)
        try super.encode(to: container.superEncoder())
    }
}
