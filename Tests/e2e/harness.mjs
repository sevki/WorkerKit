// Starts workerd or celld serving a worker.mjs + one .wasm module from a
// temporary directory, with plain-text variables and Durable Object
// namespaces as env bindings.
//
//   E2E_RUNTIMES  comma-separated runtimes to run (default "workerd").
//                 "celld" needs a `celld` binary on PATH (or CELLD_BIN).

import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
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

const launchers = {
  async workerd(directory, port, wasmName, { vars, durableObjects }) {
    const bindings = [
      ...Object.entries(vars)
        .map(([name, value]) => `(name = ${JSON.stringify(name)}, text = ${JSON.stringify(value)})`),
      ...Object.entries(durableObjects)
        .map(([name, className]) => `(name = ${JSON.stringify(name)}, durableObjectNamespace = ${JSON.stringify(className)})`),
    ].join(", ");
    const namespaces = Object.values(durableObjects)
      .map((className) => `(className = ${JSON.stringify(className)}, uniqueKey = "workers-swift-e2e-${className}")`)
      .join(", ");
    await writeFile(join(directory, "config.capnp"), `
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [(name = "main", worker = .worker)],
  sockets = [(name = "http", address = "127.0.0.1:${port}", http = (), service = "main")],
);

const worker :Workerd.Worker = (
  modules = [
    (name = "worker.mjs", esModule = embed "worker.mjs"),
    (name = "${wasmName}", wasm = embed "${wasmName}"),
  ],
  bindings = [${bindings}],
  durableObjectNamespaces = [${namespaces}],
  durableObjectStorage = (inMemory = void),
  compatibilityDate = "2026-01-01",
);
`);
    const binary = process.env.WORKERD_BIN ?? require("workerd").default;
    return [binary, ["serve", join(directory, "config.capnp")]];
  },

  async celld(directory, port, _wasmName, { vars, durableObjects }) {
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
    }, null, 2));
    const binary = process.env.CELLD_BIN ?? "celld";
    return [binary, ["dev", directory, "--port", String(port), "--logs"]];
  },
};

/// Serves `files` ({ "worker.mjs": source, [wasmName]: bytes }) with
/// `runtime` and resolves once it answers HTTP. `vars` are plain-text env
/// variables; `durableObjects` maps binding names to Durable Object classes.
export async function serve(runtime, files, wasmName, { vars = {}, durableObjects = {} } = {}) {
  const launch = launchers[runtime];
  if (!launch) {
    throw new Error(`unknown runtime ${runtime}`);
  }

  const directory = await mkdtemp(join(tmpdir(), `workers-swift-${runtime}-`));
  for (const [name, contents] of Object.entries(files)) {
    await writeFile(join(directory, name), contents);
  }

  const port = await freePort();
  const [command, args] = await launch(directory, port, wasmName, { vars, durableObjects });
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
