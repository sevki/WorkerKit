// End-to-end tests: serve Examples/workerd-celld/worker.mjs from real workerd
// and celld processes and send HTTP requests to them.
//
//   WORKERS_SWIFT_WASM  path to a built WorkersSwift.wasm. Without it, the
//                       tests use the ABI fixture in fixture.wat instead.
//   E2E_RUNTIMES        comma-separated runtimes to run (default "workerd").
//                       "celld" needs a `celld` binary on PATH (or CELLD_BIN).

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { copyFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const shimPath = join(root, "Examples/workerd-celld/worker.mjs");
const require = (await import("node:module")).createRequire(import.meta.url);

const runtimes = (process.env.E2E_RUNTIMES ?? "workerd")
  .split(",")
  .map((name) => name.trim())
  .filter(Boolean);

async function wasmBytes() {
  if (process.env.WORKERS_SWIFT_WASM) {
    return readFile(process.env.WORKERS_SWIFT_WASM);
  }

  const wabt = await require("wabt")();
  const source = await readFile(join(root, "Tests/e2e/fixture.wat"), "utf8");
  const module = wabt.parseWat("fixture.wat", source, { bulk_memory: true });
  try {
    return Buffer.from(module.toBinary({}).buffer);
  } finally {
    module.destroy();
  }
}

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
  async workerd(directory, port) {
    await writeFile(join(directory, "config.capnp"), `
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [(name = "main", worker = .worker)],
  sockets = [(name = "http", address = "127.0.0.1:${port}", http = (), service = "main")],
);

const worker :Workerd.Worker = (
  modules = [
    (name = "worker.mjs", esModule = embed "worker.mjs"),
    (name = "WorkersSwift.wasm", wasm = embed "WorkersSwift.wasm"),
  ],
  compatibilityDate = "2026-01-01",
);
`);
    const binary = process.env.WORKERD_BIN ?? require("workerd").default;
    return [binary, ["serve", join(directory, "config.capnp")]];
  },

  async celld(directory, port) {
    await writeFile(join(directory, "wrangler.jsonc"), JSON.stringify({
      name: "workers-swift-e2e",
      main: "worker.mjs",
      no_bundle: true,
      compatibility_date: "2026-01-01",
    }, null, 2));
    const binary = process.env.CELLD_BIN ?? "celld";
    return [binary, ["dev", directory, "--port", String(port), "--logs"]];
  },
};

async function waitForServer(baseURL, child, output) {
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`runtime exited with ${child.exitCode}:\n${output.join("")}`);
    }
    try {
      await fetch(`${baseURL}/health`);
      return;
    } catch {
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 250));
    }
  }
  throw new Error(`runtime did not start listening:\n${output.join("")}`);
}

for (const runtime of runtimes) {
  describe(`worker.mjs on ${runtime}`, () => {
    let directory;
    let child;
    let baseURL;
    const output = [];

    before(async () => {
      const launch = launchers[runtime];
      assert.ok(launch, `unknown runtime ${runtime}`);

      directory = await mkdtemp(join(tmpdir(), `workers-swift-${runtime}-`));
      await copyFile(shimPath, join(directory, "worker.mjs"));
      await writeFile(join(directory, "WorkersSwift.wasm"), await wasmBytes());

      const port = await freePort();
      const [command, args] = await launch(directory, port);
      child = spawn(command, args, { cwd: directory, stdio: ["ignore", "pipe", "pipe"] });
      child.stdout.on("data", (chunk) => output.push(chunk.toString()));
      child.stderr.on("data", (chunk) => output.push(chunk.toString()));

      baseURL = `http://127.0.0.1:${port}`;
      await waitForServer(baseURL, child, output);
    });

    after(async () => {
      if (child && child.exitCode === null) {
        const exited = new Promise((resolveExit) => child.once("exit", resolveExit));
        child.kill("SIGTERM");
        await exited;
      }
      if (directory) {
        await rm(directory, { recursive: true, force: true });
      }
    });

    async function request(path, init) {
      const response = await fetch(`${baseURL}${path}`, init);
      const body = await response.text();
      assert.notEqual(response.status, 500, `unexpected 500 for ${path}: ${body}\n${output.join("")}`);
      return { response, body };
    }

    test("GET / returns the hello response", async () => {
      const { response, body } = await request("/");
      assert.equal(response.status, 200);
      assert.equal(body, "Hello from Swift on workerd/celld");
      assert.equal(response.headers.get("content-type"), "text/plain; charset=utf-8");
    });

    test("GET /health returns ok", async () => {
      const { response, body } = await request("/health");
      assert.equal(response.status, 200);
      assert.equal(body, "ok");
    });

    test("POST /health falls through to 404", async () => {
      const { response, body } = await request("/health", { method: "POST" });
      assert.equal(response.status, 404);
      assert.equal(body, "Not Found");
    });

    test("an unknown path returns 404", async () => {
      const { response, body } = await request("/missing");
      assert.equal(response.status, 404);
      assert.equal(body, "Not Found");
    });

    // Only workerd is known to print worker console output to its own stdout.
    test("fd_write decodes iovecs as one UTF-8 stream", { skip: runtime !== "workerd" }, async () => {
      await request("/health");
      const deadline = Date.now() + 5_000;
      while (!output.join("").includes("split:") && Date.now() < deadline) {
        await new Promise((resolveDelay) => setTimeout(resolveDelay, 100));
      }
      assert.match(output.join(""), /split: café\n/);
    });

    test("concurrent requests each get their own response", async () => {
      const paths = Array.from({ length: 40 }, (_, index) => (index % 2 ? "/health" : "/missing"));
      const results = await Promise.all(paths.map((path) => request(path)));
      results.forEach(({ response, body }, index) => {
        assert.equal(response.status, paths[index] === "/health" ? 200 : 404);
        assert.equal(body, paths[index] === "/health" ? "ok" : "Not Found");
      });
    });
  });
}
