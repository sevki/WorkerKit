# KV

Read and write a Workers KV namespace binding, like workers-rs' `KvStore`.

## Overview

```swift
let kv = env.kv("CACHE")
try await kv.put("greeting", "hello", expirationTtl: 3600, metadata: ["by": "swift"] as [String: String])
let greeting = try await kv.get("greeting")              // String?
let entry = try await kv.getWithMetadata("greeting")     // (value: String, metadata: JSValue)?
let page = try await kv.list(prefix: "user/", limit: 100) // keys, listComplete, cursor
try await kv.delete("greeting")
```

``Env/kv(_:)`` returns a ``KVStore`` for the named binding. It also reads and
writes bytes with ``KVStore/bytes(_:)`` and `put(_:_:)` given a `[UInt8]`.

Bind a namespace with:

```jsonc
"kv_namespaces": [{ "binding": "CACHE", "id": "…" }]
```

## Topics

### The binding

- ``KVStore``

### Listing keys

- ``KVListResult``
- ``KVKey``
