// End-to-end tests: serve Examples/workerd-celld/worker.mjs from real workerd
// and celld processes and send HTTP requests to them.
//
//   WORKERS_SWIFT_WASM  path to a built WorkersSwift.wasm. Without it, the
//                       tests use the ABI fixture in fixture.wat instead.
//   E2E_RUNTIMES        see harness.mjs.

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runtimes, serve } from "./harness.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(import.meta.url);

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

for (const runtime of runtimes) {
  describe(`worker.mjs on ${runtime}`, () => {
    let server;
    let baseURL;
    let output;

    before(async () => {
      server = await serve(runtime, {
        "worker.mjs": await readFile(join(root, "Examples/workerd-celld/worker.mjs")),
        "WorkersSwift.wasm": await wasmBytes(),
      }, "WorkersSwift.wasm");
      ({ baseURL, output } = server);
    });

    after(async () => {
      await server?.stop();
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

    // The split-UTF-8 write comes from fixture.wat, and only workerd is known
    // to print worker console output to its own stdout.
    const fixtureOnWorkerd = !process.env.WORKERS_SWIFT_WASM && runtime === "workerd";
    test("fd_write decodes iovecs as one UTF-8 stream", { skip: !fixtureOnWorkerd }, async () => {
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
