;; A hand-written stand-in for WorkersSwift.wasm that speaks the same ABI and
;; serves the same routes. It lets the end-to-end tests exercise worker.mjs
;; inside workerd/celld without a Swift WebAssembly SDK. Like a SwiftPM
;; reactor, it refuses requests until `_initialize` has run, and it imports
;; WASI functions that Workers runtimes do not provide.
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "clock_time_get"
    (func $clock_time_get (param i32 i64 i32) (result i32)))
  (import "wasi_snapshot_preview1" "random_get"
    (func $random_get (param i32 i32) (result i32)))
  ;; Never called: checks that the shim stubs WASI functions it does not know.
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))

  (memory (export "memory") 2)

  (data (i32.const 16) "Hello from Swift on workerd/celld")
  (data (i32.const 64) "ok")
  (data (i32.const 80) "Not Found")
  (data (i32.const 96) "get")
  (data (i32.const 112) "/health")
  (data (i32.const 128) "fixture initialized\n")
  ;; "split: café\n" with the two bytes of "é" in separate iovecs.
  (data (i32.const 240) "split: caf\c3")
  (data (i32.const 256) "\a9\n")
  ;; 39 bytes: "content-type\0text/plain; charset=utf-8\0"
  (data (i32.const 160) "content-type\00text/plain; charset=utf-8\00")

  (global $ready (mut i32) (i32.const 0))
  (global $heap (mut i32) (i32.const 4096))
  (global $nextHandle (mut i32) (i32.const 1))

  ;; Response table: 32 slots of (status, body pointer, body length) at 1024.
  (func $slot (param $handle i32) (result i32)
    (i32.add (i32.const 1024)
      (i32.mul (i32.rem_u (local.get $handle) (i32.const 32)) (i32.const 12))))

  (func (export "_initialize")
    ;; iovec at 0: { pointer = 128, length = 20 }, written count at 8.
    (i32.store (i32.const 0) (i32.const 128))
    (i32.store (i32.const 4) (i32.const 20))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))
    ;; iovecs at 1008: { 240, 11 }, { 256, 2 }.
    (i32.store (i32.const 1008) (i32.const 240))
    (i32.store (i32.const 1012) (i32.const 11))
    (i32.store (i32.const 1016) (i32.const 256))
    (i32.store (i32.const 1020) (i32.const 2))
    (drop (call $fd_write (i32.const 1) (i32.const 1008) (i32.const 2) (i32.const 8)))
    (drop (call $random_get (i32.const 12) (i32.const 4)))
    ;; More than getRandomValues' 65,536-byte quota: the shim must chunk it.
    (if (call $random_get (i32.const 20000) (i32.const 70000))
      (then (unreachable)))
    ;; Realtime and monotonic clocks succeed; other clock IDs are EINVAL (28).
    (if (call $clock_time_get (i32.const 0) (i64.const 1) (i32.const 1000))
      (then (unreachable)))
    (if (call $clock_time_get (i32.const 1) (i64.const 1) (i32.const 1000))
      (then (unreachable)))
    (if (i32.ne (call $clock_time_get (i32.const 2) (i64.const 1) (i32.const 1000)) (i32.const 28))
      (then (unreachable)))
    (global.set $ready (i32.const 1)))

  (func (export "workers_alloc") (param $size i32) (param $alignment i32) (result i32)
    (local $pointer i32)
    (if (i32.or (i32.lt_s (local.get $size) (i32.const 0))
                (i32.ne (local.get $alignment) (i32.const 1)))
      (then (return (i32.const 0))))
    (local.set $pointer (global.get $heap))
    (global.set $heap (i32.add (global.get $heap)
      (select (local.get $size) (i32.const 1) (local.get $size))))
    (local.get $pointer))

  (func (export "workers_free") (param i32 i32 i32))

  ;; Byte-wise comparison; with $fold set, ASCII letters compare case-insensitively.
  (func $equals (param $a i32) (param $aLength i32) (param $b i32) (param $bLength i32)
                (param $fold i32) (result i32)
    (local $index i32)
    (local $byte i32)
    (if (i32.ne (local.get $aLength) (local.get $bLength))
      (then (return (i32.const 0))))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $aLength)))
        (local.set $byte (i32.load8_u (i32.add (local.get $a) (local.get $index))))
        (if (local.get $fold)
          (then (local.set $byte (i32.or (local.get $byte) (i32.const 0x20)))))
        (if (i32.ne (local.get $byte)
                    (i32.load8_u (i32.add (local.get $b) (local.get $index))))
          (then (return (i32.const 0))))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (i32.const 1))

  (func (export "workers_handle_request")
        (param $method i32) (param $methodLength i32)
        (param $path i32) (param $pathLength i32) (result i32)
    (local $handle i32)
    (local $slot i32)
    (if (i32.eqz (global.get $ready))
      (then (return (i32.const 0))))

    (local.set $handle (global.get $nextHandle))
    (global.set $nextHandle (i32.add (local.get $handle) (i32.const 1)))
    (local.set $slot (call $slot (local.get $handle)))

    ;; Default: 404 Not Found.
    (i32.store (local.get $slot) (i32.const 404))
    (i32.store offset=4 (local.get $slot) (i32.const 80))
    (i32.store offset=8 (local.get $slot) (i32.const 9))

    (if (call $equals (local.get $method) (local.get $methodLength)
                      (i32.const 96) (i32.const 3) (i32.const 1))
      (then
        (if (call $equals (local.get $path) (local.get $pathLength)
                          (i32.const 112) (i32.const 1) (i32.const 0))
          (then
            (i32.store (local.get $slot) (i32.const 200))
            (i32.store offset=4 (local.get $slot) (i32.const 16))
            (i32.store offset=8 (local.get $slot) (i32.const 33))))
        (if (call $equals (local.get $path) (local.get $pathLength)
                          (i32.const 112) (i32.const 7) (i32.const 0))
          (then
            (i32.store (local.get $slot) (i32.const 200))
            (i32.store offset=4 (local.get $slot) (i32.const 64))
            (i32.store offset=8 (local.get $slot) (i32.const 2))))))

    (local.get $handle))

  (func (export "workers_response_status") (param $handle i32) (result i32)
    (i32.load (call $slot (local.get $handle))))

  (func (export "workers_response_body_len") (param $handle i32) (result i32)
    (i32.load offset=8 (call $slot (local.get $handle))))

  (func (export "workers_response_body_copy") (param $handle i32) (param $destination i32)
    (local $slot i32)
    (local.set $slot (call $slot (local.get $handle)))
    (memory.copy (local.get $destination)
                 (i32.load offset=4 (local.get $slot))
                 (i32.load offset=8 (local.get $slot))))

  (func (export "workers_response_headers_len") (param i32) (result i32)
    (i32.const 39))

  (func (export "workers_response_headers_copy") (param i32) (param $destination i32)
    (memory.copy (local.get $destination) (i32.const 160) (i32.const 39)))

  (func (export "workers_response_release") (param i32)))
