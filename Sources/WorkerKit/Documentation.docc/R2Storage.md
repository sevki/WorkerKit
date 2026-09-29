# R2

Read and write a Workers R2 bucket binding, like workers-rs' `Bucket`.

## Overview

```swift
let bucket = env.r2("ASSETS")
try await bucket.put("greeting.txt", "hello", httpMetadata: R2HTTPMetadata(contentType: "text/plain"))
let object = try await bucket.get("greeting.txt")               // R2ObjectBody?
let text = try await object?.text()                             // String
let page = try await bucket.list(prefix: "user/", limit: 100)   // objects, truncated, cursor
try await bucket.delete("greeting.txt")
```

``Env/r2(_:)`` returns an ``R2Bucket`` for the named binding.

- ``R2Bucket/get(_:onlyIf:range:)`` returns the object's metadata and body
  together, as ``R2ObjectBody``, or `nil` when the key does not exist. When
  `onlyIf` names a condition that fails, calling `text()`/`bytes()` on the
  result throws rather than returning `nil` — this binding does not (yet)
  distinguish that case.
- ``R2Bucket/head(_:)`` returns only the metadata, as ``R2Object``.
- `put(_:_:httpMetadata:customMetadata:onlyIf:)` also reads and writes bytes
  with a `[UInt8]` in place of `String`.
- `delete(_:)` deletes one key; its `[String]` overload deletes up to 1000
  in one call.

Bind a bucket with:

```jsonc
"r2_buckets": [{ "binding": "ASSETS", "bucket_name": "…" }]
```

## Topics

### The binding

- ``R2Bucket``

### Objects

- ``R2Object``
- ``R2ObjectBody``
- ``R2HTTPMetadata``
- ``R2Checksums``

### Conditional and ranged reads

- ``R2Conditional``
- ``R2Range``

### Listing objects

- ``R2ListResult``
