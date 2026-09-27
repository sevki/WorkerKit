import JavaScriptKit

/// The worker's bindings: the runtime's `env` object.
public final class Env: @unchecked Sendable {
    /// The underlying JavaScript `env` object.
    public let jsObject: JSObject

    /// Wraps the runtime's `env` object. `@Event(.fetch)` and
    /// `@DurableObject` construct this for you.
    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// A plain-text variable, such as an entry of `vars` in wrangler.jsonc.
    public func variable(_ name: String) -> String? {
        jsObject[name].string
    }

    /// A secret, such as one set with `wrangler secret put`.
    public func secret(_ name: String) -> String? {
        jsObject[name].string
    }

    /// A Durable Object namespace binding, such as `durable_objects.bindings`
    /// in wrangler.jsonc.
    public func durableObject(_ name: String) -> DurableObjectNamespace {
        DurableObjectNamespace(jsObject[name].object!)
    }

    /// A KV namespace binding, such as `kv_namespaces` in wrangler.jsonc.
    public func kv(_ name: String) -> KVStore {
        KVStore(jsObject[name].object!)
    }

    /// A service binding, such as `services` in wrangler.jsonc.
    public func service(_ name: String) -> Fetcher {
        Fetcher(jsObject[name].object!)
    }
}
