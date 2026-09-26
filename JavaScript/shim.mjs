// The Worker entry point for a Swift worker. `swift package worker-build`
// writes it to build/worker/worker.mjs after JavaScriptKit's runtime.mjs
// (which defines SwiftRuntime), because celld's no_bundle mode takes a single
// JavaScript file.
//
// workerd and celld (like Wrangler) resolve a `.wasm` import to a compiled
// `WebAssembly.Module`.
import wasmModule from "./WorkersSwift.wasm";

const WASI_EBADF = 8;
const WASI_EINVAL = 28;
const WASI_ENOSYS = 52;

// stdout and stderr are byte streams across fd_write calls: a UTF-8 sequence
// or a line may span several writes. Each keeps its own decoder and logs
// complete lines; flushConsole() logs the rest when a request finishes.
const MAX_PENDING_OUTPUT = 8192;

class ConsoleStream {
  constructor(log) {
    this.log = log;
    this.decoder = new TextDecoder();
    this.pending = "";
  }

  write(bytes) {
    this.pending += this.decoder.decode(bytes, { stream: true });
    const lines = this.pending.split("\n");
    this.pending = lines.pop();
    for (const line of lines) {
      this.log(line);
    }
    if (this.pending.length > MAX_PENDING_OUTPUT) {
      this.log(this.pending);
      this.pending = "";
    }
  }

  // Logs the decoded text so far. The decoder keeps any partial UTF-8
  // sequence, because a concurrent request may still be writing its rest.
  flush() {
    if (this.pending) {
      this.log(this.pending);
      this.pending = "";
    }
  }
}

const streams = {
  1: new ConsoleStream((line) => console.log(line)),
  2: new ConsoleStream((line) => console.error(line)),
};

function flushConsole() {
  streams[1].flush();
  streams[2].flush();
}

// Runs `call` and then logs any output it left without a final newline.
async function flushingConsole(call) {
  try {
    return await call();
  } finally {
    flushConsole();
  }
}

// Workers runtimes provide no WASI. Give the Swift runtime the few calls it
// makes and stub every other import the module declares.
function buildImportObject(module, swift, getMemory) {
  const view = () => new DataView(getMemory().buffer);
  const zeroCounts = (countPointer, sizePointer) => {
    view().setUint32(countPointer, 0, true);
    view().setUint32(sizePointer, 0, true);
    return 0;
  };
  const wasi = {
    args_sizes_get: zeroCounts,
    args_get: () => 0,
    environ_sizes_get: zeroCounts,
    environ_get: () => 0,
    clock_time_get(clockId, _precision, resultPointer) {
      let nanoseconds;
      if (clockId === 0) {
        nanoseconds = BigInt(Date.now()) * 1_000_000n; // realtime
      } else if (clockId === 1) {
        nanoseconds = BigInt(Math.round(performance.now() * 1_000_000)); // monotonic
      } else {
        return WASI_EINVAL;
      }
      view().setBigUint64(resultPointer, nanoseconds, true);
      return 0;
    },
    random_get(pointer, length) {
      // getRandomValues fills at most 65,536 bytes per call; WASI allows more.
      for (let offset = 0; offset < length; offset += 65_536) {
        const chunk = Math.min(65_536, length - offset);
        crypto.getRandomValues(new Uint8Array(getMemory().buffer, pointer + offset, chunk));
      }
      return 0;
    },
    fd_write(fd, iovs, iovsLength, writtenPointer) {
      const stream = streams[fd];
      if (!stream) {
        return WASI_EBADF;
      }
      let written = 0;
      for (let index = 0; index < iovsLength; index += 1) {
        const pointer = view().getUint32(iovs + index * 8, true);
        const length = view().getUint32(iovs + index * 8 + 4, true);
        stream.write(new Uint8Array(getMemory().buffer, pointer, length));
        written += length;
      }
      view().setUint32(writtenPointer, written, true);
      return 0;
    },
    proc_exit(code) {
      throw new Error(`Swift Wasm module exited with code ${code}`);
    },
  };

  const importObject = { javascript_kit: swift.wasmImports };
  for (const { module: moduleName, name, kind } of WebAssembly.Module.imports(module)) {
    if (kind !== "function") {
      continue;
    }
    importObject[moduleName] ??= {};
    importObject[moduleName][name] ??= moduleName === "wasi_snapshot_preview1"
      ? (wasi[name] ?? (() => WASI_ENOSYS))
      : () => {
          throw new Error(`Unexpected call to ${moduleName}.${name}`);
        };
  }
  return importObject;
}

async function start() {
  const module = wasmModule instanceof WebAssembly.Module
    ? wasmModule
    : await WebAssembly.compile(wasmModule);
  const swift = new SwiftRuntime();
  let memory;
  const instance = await WebAssembly.instantiate(
    module,
    buildImportObject(module, swift, () => memory),
  );
  memory = instance.exports.memory;

  // SwiftPM links the module with `-mexec-model=reactor`; a reactor must run
  // its static constructors through `_initialize` before any other export.
  instance.exports._initialize?.();
  swift.setInstance(instance);

  // A reactor module does not export `main`, so SwiftRuntime.main() would not
  // reach Swift. Instead, `@Event(.fetch)` generates `workers_js_main`, which
  // registers globalThis.__workersSwiftFetch, and each `@DurableObject` class
  // generates a `workers_do:<Class>` export, which registers its factory in
  // globalThis.__workersSwiftDurableObjects.
  instance.exports.workers_js_main?.();
  for (const [name, value] of Object.entries(instance.exports)) {
    if (name.startsWith("workers_do:") && typeof value === "function") {
      value();
    }
  }
}

let started;

function ensureStarted() {
  started ??= start().catch((error) => {
    started = undefined;
    throw error;
  });
  return started;
}

// Called by the Durable Object classes that `worker-build` appends to this
// module: creates the Swift object and returns its fetch/alarm/rpc entry points.
async function __workersSwiftDurableObject(name, ctx, env) {
  await ensureStarted();
  const factory = globalThis.__workersSwiftDurableObjects?.[name];
  if (typeof factory !== "function") {
    throw new Error(`The Swift worker has no @DurableObject class ${name}`);
  }
  const object = factory(ctx, env);
  return {
    fetch: (request) => flushingConsole(() => object.fetch(request)),
    alarm: () => flushingConsole(() => object.alarm()),
    rpc: (method, args) => flushingConsole(() => object.rpc(method, args)),
  };
}

export default {
  async fetch(request, env, ctx) {
    await ensureStarted();
    const handler = globalThis.__workersSwiftFetch;
    if (typeof handler !== "function") {
      throw new Error("The Swift worker has no @Event(.fetch) function");
    }
    return flushingConsole(() => handler(request, env, ctx));
  },
};
