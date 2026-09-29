// Starts workerd or celld serving a worker.mjs + one .wasm module from a
// temporary directory, with plain-text variables, Durable Object namespaces
// and KV namespaces as env bindings.
//
//   E2E_RUNTIMES  comma-separated runtimes to run (default "workerd").
//                 "celld" needs a `celld` binary on PATH (or CELLD_BIN).

import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

const require = createRequire(import.meta.url);

export const runtimes = (process.env.E2E_RUNTIMES ?? "workerd")
  .split(",")
  .map((name) => name.trim())
  .filter(Boolean);

function freePort() {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolvePort(port));
    });
  });
}

// workerd sends a KV binding's operations as HTTP requests to a service:
// GET, PUT and DELETE https://fake-host/<key>?urlencoded=true (metadata in
// the CF-KV-Metadata header), and GET https://fake-host?prefix=&key_count_limit=&cursor=
// to list. This worker answers them from memory.
const kvService = `
const entries = new Map();

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/") {
      const prefix = url.searchParams.get("prefix") ?? "";
      const limit = Number(url.searchParams.get("key_count_limit") ?? 1000);
      const start = Number(url.searchParams.get("cursor") || 0);
      const names = [...entries.keys()].filter((name) => name.startsWith(prefix)).sort();
      const page = names.slice(start, start + limit);
      const complete = start + limit >= names.length;
      return Response.json({
        keys: page.map((name) => ({ name, ...entries.get(name).listed })),
        list_complete: complete,
        ...(complete ? {} : { cursor: String(start + limit) }),
        cacheStatus: null,
      });
    }
    const key = decodeURIComponent(url.pathname.slice(1));
    switch (request.method) {
      case "GET": {
        const entry = entries.get(key);
        if (!entry) {
          return new Response(null, { status: 404 });
        }
        const headers = entry.metadata === null ? {} : { "CF-KV-Metadata": entry.metadata };
        return new Response(entry.value, { headers });
      }
      case "PUT": {
        const metadata = request.headers.get("CF-KV-Metadata");
        const ttl = url.searchParams.get("expiration_ttl");
        const expiration = url.searchParams.get("expiration")
          ?? (ttl === null ? null : String(Math.floor(Date.now() / 1000) + Number(ttl)));
        entries.set(key, {
          value: await request.arrayBuffer(),
          metadata,
          listed: {
            ...(expiration === null ? {} : { expiration: Number(expiration) }),
            ...(metadata === null ? {} : { metadata: JSON.parse(metadata) }),
          },
        });
        return new Response(null);
      }
      case "DELETE":
        entries.delete(key);
        return new Response(null);
      default:
        return new Response(null, { status: 405 });
    }
  },
};
`;

// workerd sends every r2Bucket binding operation as an HTTP request to a
// service, always GET (head/get/list) or PUT (put/delete): the request
// itself - a JSON object discriminated by a "method" field, matching
// workerd's R2BindingRequest capnp schema - travels in the CF-R2-Request
// header for a GET, or as a length-prefixed JSON blob at the front of the
// body for a PUT (CF-R2-Metadata-Size gives that prefix's byte length; the
// object's raw bytes, if any, follow immediately after). The response
// mirrors that shape: CF-R2-Metadata-Size names a JSON prefix of the body,
// with the object's raw bytes (get only) following. A missing key answers
// 404 with a CF-R2-Error header carrying R2's own "object not found" code
// (10007) - without it, the real binding can't tell "not found" apart from
// a generic error and throws instead of returning null. This worker answers
// from memory.
const r2Service = `
const entries = new Map();

function notFound() {
  return new Response(null, {
    status: 404,
    headers: { "CF-R2-Error": JSON.stringify({ version: 0, v4code: 10007, message: "The specified key does not exist." }) },
  });
}

function metadataFor(key, entry) {
  return {
    name: key,
    version: "1",
    size: entry.value.byteLength,
    etag: entry.etag,
    uploaded: entry.uploaded,
    httpFields: entry.httpFields,
    customFields: Object.entries(entry.customFields).map(([k, v]) => ({ k, v })),
  };
}

// Concatenates the JSON metadata and (optionally) the object's raw bytes
// into one body, with CF-R2-Metadata-Size marking where the JSON ends.
function metadataResponse(metadata, body) {
  const json = new TextEncoder().encode(JSON.stringify(metadata));
  const bytes = body ? new Uint8Array(json.length + body.byteLength) : json;
  if (body) {
    bytes.set(json, 0);
    bytes.set(body, json.length);
  }
  return new Response(bytes, { headers: { "CF-R2-Metadata-Size": String(json.length) } });
}

export default {
  async fetch(request) {
    if (request.method === "GET") {
      const req = JSON.parse(request.headers.get("CF-R2-Request"));
      if (req.method === "list") {
        const prefix = req.prefix ?? "";
        const limit = req.limit ?? 1000;
        const start = req.cursor ? Number(req.cursor) : 0;
        const names = [...entries.keys()].filter((name) => name.startsWith(prefix)).sort();
        const page = names.slice(start, start + limit);
        const truncated = start + limit < names.length;
        return metadataResponse({
          objects: page.map((name) => metadataFor(name, entries.get(name))),
          truncated,
          cursor: truncated ? String(start + limit) : "",
          delimitedPrefixes: [],
        });
      }
      const entry = entries.get(req.object);
      if (!entry) {
        return notFound();
      }
      return req.method === "head"
        ? metadataResponse(metadataFor(req.object, entry))
        : metadataResponse(metadataFor(req.object, entry), entry.value);
    }

    // PUT: either a put or a delete, told apart by the "method" field in
    // the JSON prefix of the body.
    const metadataSize = Number(request.headers.get("CF-R2-Metadata-Size"));
    const body = new Uint8Array(await request.arrayBuffer());
    const req = JSON.parse(new TextDecoder().decode(body.subarray(0, metadataSize)));
    if (req.method === "delete") {
      for (const key of req.object !== undefined ? [req.object] : req.objects) {
        entries.delete(key);
      }
      return new Response(JSON.stringify({}));
    }
    const value = body.subarray(metadataSize);
    const customFields = Object.fromEntries((req.customFields ?? []).map(({ k, v }) => [k, v]));
    const entry = {
      value,
      etag: Math.random().toString(36).slice(2),
      uploaded: Date.now(),
      httpFields: req.httpFields ?? {},
      customFields,
    };
    entries.set(req.object, entry);
    return metadataResponse(metadataFor(req.object, entry));
  },
};
`;

const launchers = {
  async workerd(directory, port, wasmName, { vars, durableObjects, kvNamespaces, r2Buckets, selfBinding }) {
    const bindings = [
      ...(selfBinding ? [`(name = ${JSON.stringify(selfBinding)}, service = "main")`] : []),
      ...Object.entries(vars)
        .map(([name, value]) => `(name = ${JSON.stringify(name)}, text = ${JSON.stringify(value)})`),
      ...Object.entries(durableObjects)
        .map(([name, className]) => `(name = ${JSON.stringify(name)}, durableObjectNamespace = ${JSON.stringify(className)})`),
      ...Object.keys(kvNamespaces)
        .map((name) => `(name = ${JSON.stringify(name)}, kvNamespace = "kv-${name}")`),
      ...Object.keys(r2Buckets)
        .map((name) => `(name = ${JSON.stringify(name)}, r2Bucket = "r2-${name}")`),
    ].join(", ");
    const kvServices = Object.keys(kvNamespaces)
      .map((name) => `, (name = "kv-${name}", worker = .kvWorker)`)
      .join("");
    const r2Services = Object.keys(r2Buckets)
      .map((name) => `, (name = "r2-${name}", worker = .r2Worker)`)
      .join("");
    await writeFile(join(directory, "kv-service.mjs"), kvService);
    await writeFile(join(directory, "r2-service.mjs"), r2Service);
    // workerd requires a DiskDirectory's path to already exist.
    await mkdir(join(directory, "disk"));
    // enableSql = true exposes state.storage.sql (SQLStorage); every
    // namespace gets it, since it is harmless for a Durable Object that
    // never touches it. Unlike inMemory, a SQLite-backed namespace needs
    // disk-backed storage, so a DiskDirectory service backs it with a
    // subdirectory of this run's own temporary directory.
    const namespaces = Object.values(durableObjects)
      .map((className) => `(className = ${JSON.stringify(className)}, uniqueKey = "workers-swift-e2e-${className}", enableSql = true)`)
      .join(", ");
    await writeFile(join(directory, "config.capnp"), `
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "main", worker = .worker)${kvServices}${r2Services},
    (name = "disk", disk = (path = ${JSON.stringify(join(directory, "disk"))}, writable = true)),
  ],
  sockets = [(name = "http", address = "127.0.0.1:${port}", http = (), service = "main")],
);

const worker :Workerd.Worker = (
  modules = [
    (name = "worker.mjs", esModule = embed "worker.mjs"),
    (name = "${wasmName}", wasm = embed "${wasmName}"),
  ],
  bindings = [${bindings}],
  durableObjectNamespaces = [${namespaces}],
  durableObjectStorage = (localDisk = "disk"),
  compatibilityDate = "2026-01-01",
);

const kvWorker :Workerd.Worker = (
  modules = [(name = "kv-service.mjs", esModule = embed "kv-service.mjs")],
  compatibilityDate = "2026-01-01",
);

const r2Worker :Workerd.Worker = (
  modules = [(name = "r2-service.mjs", esModule = embed "r2-service.mjs")],
  compatibilityDate = "2026-01-01",
);
`);
    const binary = process.env.WORKERD_BIN ?? require("workerd").default;
    return [binary, ["serve", join(directory, "config.capnp")]];
  },

  async celld(directory, port, _wasmName, { vars, durableObjects, kvNamespaces, r2Buckets, selfBinding }) {
    const classNames = [...new Set(Object.values(durableObjects))];
    await writeFile(join(directory, "wrangler.jsonc"), JSON.stringify({
      name: "workers-swift-e2e",
      main: "worker.mjs",
      no_bundle: true,
      compatibility_date: "2026-01-01",
      vars,
      durable_objects: {
        bindings: Object.entries(durableObjects).map(([name, className]) => ({ name, class_name: className })),
      },
      migrations: classNames.length ? [{ tag: "v1", new_sqlite_classes: classNames }] : [],
      kv_namespaces: Object.entries(kvNamespaces).map(([binding, id]) => ({ binding, id })),
      r2_buckets: Object.entries(r2Buckets).map(([binding, bucketName]) => ({ binding, bucket_name: bucketName })),
      services: selfBinding ? [{ binding: selfBinding, service: "workers-swift-e2e" }] : [],
    }, null, 2));
    const binary = process.env.CELLD_BIN ?? "celld";
    return [binary, ["dev", directory, "--port", String(port), "--logs"]];
  },
};

/// Serves `files` ({ "worker.mjs": source, [wasmName]: bytes }) with
/// `runtime` and resolves once it answers HTTP. `vars` are plain-text env
/// variables; `durableObjects` maps binding names to Durable Object classes;
/// `kvNamespaces` maps binding names to KV namespace ids, which start empty;
/// `r2Buckets` maps binding names to R2 bucket names, which start empty;
/// `selfBinding` names a service binding to the worker itself.
export async function serve(
  runtime, files, wasmName,
  { vars = {}, durableObjects = {}, kvNamespaces = {}, r2Buckets = {}, selfBinding } = {}
) {
  const launch = launchers[runtime];
  if (!launch) {
    throw new Error(`unknown runtime ${runtime}`);
  }

  const directory = await mkdtemp(join(tmpdir(), `workers-swift-${runtime}-`));
  for (const [name, contents] of Object.entries(files)) {
    await writeFile(join(directory, name), contents);
  }

  const port = await freePort();
  const [command, args] = await launch(directory, port, wasmName, { vars, durableObjects, kvNamespaces, r2Buckets, selfBinding });
  const child = spawn(command, args, { cwd: directory, stdio: ["ignore", "pipe", "pipe"] });
  const output = [];
  child.stdout.on("data", (chunk) => output.push(chunk.toString()));
  child.stderr.on("data", (chunk) => output.push(chunk.toString()));

  const baseURL = `http://127.0.0.1:${port}`;
  const stop = async () => {
    if (child.exitCode === null) {
      const exited = new Promise((resolveExit) => child.once("exit", resolveExit));
      child.kill("SIGTERM");
      await exited;
    }
    await rm(directory, { recursive: true, force: true });
  };

  const deadline = Date.now() + 120_000;
  while (true) {
    if (child.exitCode !== null) {
      await stop();
      throw new Error(`runtime exited with ${child.exitCode}:\n${output.join("")}`);
    }
    try {
      await fetch(baseURL);
      break;
    } catch {
      if (Date.now() > deadline) {
        await stop();
        throw new Error(`runtime did not start listening:\n${output.join("")}`);
      }
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 250));
    }
  }

  return { baseURL, output, stop };
}
