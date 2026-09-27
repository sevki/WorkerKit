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

const launchers = {
  async workerd(directory, port, wasmName, { vars, durableObjects, kvNamespaces, selfBinding }) {
    const bindings = [
      ...(selfBinding ? [`(name = ${JSON.stringify(selfBinding)}, service = "main")`] : []),
      ...Object.entries(vars)
        .map(([name, value]) => `(name = ${JSON.stringify(name)}, text = ${JSON.stringify(value)})`),
      ...Object.entries(durableObjects)
        .map(([name, className]) => `(name = ${JSON.stringify(name)}, durableObjectNamespace = ${JSON.stringify(className)})`),
      ...Object.keys(kvNamespaces)
        .map((name) => `(name = ${JSON.stringify(name)}, kvNamespace = "kv-${name}")`),
    ].join(", ");
    const kvServices = Object.keys(kvNamespaces)
      .map((name) => `, (name = "kv-${name}", worker = .kvWorker)`)
      .join("");
    await writeFile(join(directory, "kv-service.mjs"), kvService);
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
    (name = "main", worker = .worker)${kvServices},
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
`);
    const binary = process.env.WORKERD_BIN ?? require("workerd").default;
    return [binary, ["serve", join(directory, "config.capnp")]];
  },

  async celld(directory, port, _wasmName, { vars, durableObjects, kvNamespaces, selfBinding }) {
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
/// `selfBinding` names a service binding to the worker itself.
export async function serve(runtime, files, wasmName, { vars = {}, durableObjects = {}, kvNamespaces = {}, selfBinding } = {}) {
  const launch = launchers[runtime];
  if (!launch) {
    throw new Error(`unknown runtime ${runtime}`);
  }

  const directory = await mkdtemp(join(tmpdir(), `workers-swift-${runtime}-`));
  for (const [name, contents] of Object.entries(files)) {
    await writeFile(join(directory, name), contents);
  }

  const port = await freePort();
  const [command, args] = await launch(directory, port, wasmName, { vars, durableObjects, kvNamespaces, selfBinding });
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
