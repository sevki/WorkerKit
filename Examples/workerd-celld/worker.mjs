// workerd and celld (like Wrangler) resolve a `.wasm` import to a compiled
// `WebAssembly.Module`, not to bytes or an instance.
import wasmModule from "./WorkersSwift.wasm";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const WASM_ALIGNMENT = 1;

const WASI_MODULE = "wasi_snapshot_preview1";
const WASI_ESUCCESS = 0;
const WASI_EBADF = 8;
const WASI_EINVAL = 28;
const WASI_CLOCK_REALTIME = 0;
const WASI_CLOCK_MONOTONIC = 1;
const WASI_ENOSYS = 52;

class WasiExit extends Error {
  constructor(code) {
    super(`Swift Wasm module exited with code ${code}`);
    this.code = code;
  }
}

// Workers runtimes do not provide WASI. Swift's Wasm SDKs import a handful of
// WASI functions (stdio for fatalError messages, clocks, randomness), so give
// them the minimum they need and answer anything else with ENOSYS.
function createWasiImports(getMemory) {
  const view = () => new DataView(getMemory().buffer);
  const bytes = () => new Uint8Array(getMemory().buffer);

  const zeroCounts = (countPointer, sizePointer) => {
    view().setUint32(countPointer, 0, true);
    view().setUint32(sizePointer, 0, true);
    return WASI_ESUCCESS;
  };

  return {
    args_sizes_get: zeroCounts,
    args_get: () => WASI_ESUCCESS,
    environ_sizes_get: zeroCounts,
    environ_get: () => WASI_ESUCCESS,
    clock_time_get(clockId, _precision, resultPointer) {
      let nanoseconds;
      if (clockId === WASI_CLOCK_REALTIME) {
        nanoseconds = BigInt(Date.now()) * 1_000_000n;
      } else if (clockId === WASI_CLOCK_MONOTONIC) {
        nanoseconds = BigInt(Math.round(performance.now() * 1_000_000));
      } else {
        return WASI_EINVAL;
      }
      view().setBigUint64(resultPointer, nanoseconds, true);
      return WASI_ESUCCESS;
    },
    random_get(pointer, length) {
      // getRandomValues fills at most 65,536 bytes per call; WASI allows more.
      for (let offset = 0; offset < length; offset += 65_536) {
        const end = Math.min(offset + 65_536, length);
        crypto.getRandomValues(bytes().subarray(pointer + offset, pointer + end));
      }
      return WASI_ESUCCESS;
    },
    fd_write(fd, iovs, iovsLength, writtenPointer) {
      if (fd !== 1 && fd !== 2) {
        return WASI_EBADF;
      }

      // The iovecs form one byte stream: a UTF-8 sequence may span two.
      const memory = view();
      const streamDecoder = new TextDecoder();
      let text = "";
      let written = 0;
      for (let index = 0; index < iovsLength; index += 1) {
        const pointer = memory.getUint32(iovs + index * 8, true);
        const length = memory.getUint32(iovs + index * 8 + 4, true);
        text += streamDecoder.decode(bytes().subarray(pointer, pointer + length), { stream: true });
        written += length;
      }
      text += streamDecoder.decode();
      (fd === 1 ? console.log : console.error)(text.replace(/\n$/, ""));
      memory.setUint32(writtenPointer, written, true);
      return WASI_ESUCCESS;
    },
    proc_exit(code) {
      throw new WasiExit(code);
    },
    sched_yield: () => WASI_ESUCCESS,
  };
}

function buildImportObject(module, hostImports, getMemory) {
  const wasi = createWasiImports(getMemory);
  const importObject = { ...hostImports };

  for (const { module: moduleName, name, kind } of WebAssembly.Module.imports(module)) {
    if (moduleName !== WASI_MODULE || kind !== "function") {
      continue;
    }
    importObject[WASI_MODULE] ??= {};
    importObject[WASI_MODULE][name] ??= wasi[name] ?? (() => WASI_ENOSYS);
  }

  return importObject;
}

async function instantiate(source, hostImports) {
  const module = source instanceof WebAssembly.Module
    ? source
    : await WebAssembly.compile(source);

  let memory;
  const importObject = buildImportObject(module, hostImports, () => memory);
  // `instantiate(Module)` resolves to an Instance, unlike
  // `instantiate(bytes)`, which resolves to `{ module, instance }`.
  const instance = await WebAssembly.instantiate(module, importObject);
  memory = instance.exports.memory;

  // SwiftPM links the module with `-mexec-model=reactor`; a reactor must run
  // its static constructors through `_initialize` before any other export.
  instance.exports._initialize?.();

  return instance;
}

function writeString(instance, value) {
  const bytes = encoder.encode(value);
  const pointer = instance.exports.workers_alloc(bytes.length, WASM_ALIGNMENT);

  if (!pointer) {
    throw new Error("Swift Wasm allocation failed for request string");
  }

  if (bytes.length > 0) {
    new Uint8Array(instance.exports.memory.buffer, pointer, bytes.length).set(bytes);
  }

  return { pointer, length: bytes.length, alignment: WASM_ALIGNMENT };
}

function freeString(instance, string) {
  if (string) {
    instance.exports.workers_free(string.pointer, string.length, string.alignment);
  }
}

// Copies a response field out of Swift memory through its `*_len` and
// `*_copy` exports.
function readCopiedBytes(instance, handle, field) {
  const length = instance.exports[`workers_response_${field}_len`](handle);
  if (length === 0) {
    return new Uint8Array();
  }
  if (length < 0) {
    throw new Error(`Swift Wasm returned an invalid negative response ${field} length`);
  }

  const pointer = instance.exports.workers_alloc(length, WASM_ALIGNMENT);
  if (!pointer) {
    throw new Error(`Swift Wasm allocation failed for response ${field} copy`);
  }

  try {
    instance.exports[`workers_response_${field}_copy`](handle, pointer);
    return new Uint8Array(instance.exports.memory.buffer, pointer, length).slice();
  } finally {
    instance.exports.workers_free(pointer, length, WASM_ALIGNMENT);
  }
}

// Headers arrive as `name\0value\0` pairs.
function decodeHeaders(bytes) {
  const parts = decoder.decode(bytes).split("\0");
  const headers = new Headers();
  for (let index = 0; index + 1 < parts.length; index += 2) {
    headers.append(parts[index], parts[index + 1]);
  }
  return headers;
}

export function createWorkerHandler(source = wasmModule, hostImports = {}) {
  let instancePromise;

  function loadInstance() {
    instancePromise ??= instantiate(source, hostImports).catch((error) => {
      instancePromise = undefined;
      throw error;
    });
    return instancePromise;
  }

  return {
    async fetch(request) {
      const instance = await loadInstance();
      const url = new URL(request.url);

      let method;
      let path;
      let handle = 0;

      try {
        method = writeString(instance, request.method);
        path = writeString(instance, url.pathname);

        handle = instance.exports.workers_handle_request(
          method.pointer,
          method.length,
          path.pointer,
          path.length,
        );
        if (handle === 0) {
          throw new Error("Swift Wasm request bridge rejected malformed input");
        }
        const status = instance.exports.workers_response_status(handle);
        const headers = decodeHeaders(readCopiedBytes(instance, handle, "headers"));
        const body = readCopiedBytes(instance, handle, "body");

        // Response rejects any body, even an empty one, for these statuses.
        const bodyless = status === 204 || status === 205 || status === 304;
        return new Response(bodyless ? null : body, { status, headers });
      } finally {
        freeString(instance, method);
        freeString(instance, path);

        if (handle) {
          instance.exports.workers_response_release(handle);
        }
      }
    },
  };
}

export default createWorkerHandler();
