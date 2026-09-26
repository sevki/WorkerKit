// End-to-end tests: serve the output of `swift package worker-build`
// (worker.mjs + WorkersSwift.wasm, from Sources/HelloWorker) with real workerd
// and celld processes and send HTTP requests to them.
//
//   WORKER_DIR    directory holding the built worker (default: build/worker).
//                 When it is set, a missing build fails instead of skipping.
//   E2E_RUNTIMES  see harness.mjs.

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runtimes, serve } from "./harness.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const workerDirectory = resolve(root, process.env.WORKER_DIR ?? "build/worker");
const built = existsSync(join(workerDirectory, "WorkersSwift.wasm"));

for (const runtime of runtimes) {
  const skip = !built && !process.env.WORKER_DIR
    && `no built worker in ${workerDirectory}; run swift package worker-build`;

  describe(`Swift worker on ${runtime}`, { skip }, () => {
    let server;

    before(async () => {
      server = await serve(runtime, {
        "worker.mjs": await readFile(join(workerDirectory, "worker.mjs")),
        "WorkersSwift.wasm": await readFile(join(workerDirectory, "WorkersSwift.wasm")),
      }, "WorkersSwift.wasm", {
        vars: { GREETING: "hello from env" },
        durableObjects: { COUNTER: "Counter" },
      });
    });

    after(async () => {
      await server?.stop();
    });

    async function request(path, init) {
      const response = await fetch(`${server.baseURL}${path}`, init);
      const body = await response.text();
      return { response, body };
    }

    function assertNotCrashed({ response, body }, path) {
      assert.notEqual(response.status, 500, `unexpected 500 for ${path}: ${body}\n${server.output.join("")}`);
    }

    test("GET / returns a plain-text Response built in Swift", async () => {
      const result = await request("/");
      assertNotCrashed(result, "/");
      assert.equal(result.response.status, 200);
      assert.equal(result.body, "Hello from Swift on workerd/celld");
      assert.equal(result.response.headers.get("content-type"), "text/plain; charset=utf-8");
    });

    test("POST /health falls through to 404", async () => {
      const result = await request("/health", { method: "POST" });
      assert.equal(result.response.status, 404);
      assert.equal(result.body, "Not Found");
    });

    test("an unknown path returns 404", async () => {
      const result = await request("/missing");
      assert.equal(result.response.status, 404);
    });

    test("Request.headers and Response headers round-trip", async () => {
      const result = await request("/headers", { headers: { "x-echo": "swift" } });
      assertNotCrashed(result, "/headers");
      assert.equal(result.body, "swift");
      assert.equal(result.response.headers.get("x-echo"), "swift");
    });

    test("Env reads a plain-text variable", async () => {
      const result = await request("/env");
      assertNotCrashed(result, "/env");
      assert.equal(result.body, "hello from env");
    });

    test("Request.text() awaits the body", async () => {
      const result = await request("/echo", { method: "POST", body: "café ☕" });
      assertNotCrashed(result, "/echo");
      assert.equal(result.body, "café ☕");
    });

    test("an awaited Web API promise (crypto.subtle) resolves in Swift", async () => {
      const result = await request("/digest");
      assertNotCrashed(result, "/digest");
      assert.equal(result.body, createHash("sha256").update("hello").digest("hex"));
    });

    test("Response.empty() is a bodyless 204", async () => {
      const result = await request("/no-content");
      assert.equal(result.response.status, 204);
      assert.equal(result.body, "");
    });

    test("a thrown error becomes a 500 and the worker keeps serving", async () => {
      const failed = await request("/throw");
      assert.equal(failed.response.status, 500);
      assert.equal(failed.body, "Internal Server Error");

      const next = await request("/health");
      assert.equal(next.body, "ok");
    });

    // Only workerd is known to print worker console output to its own stdout.
    test("stdout survives writes that split a character and a line", { skip: runtime !== "workerd" }, async () => {
      const result = await request("/log");
      assertNotCrashed(result, "/log");
      const deadline = Date.now() + 5_000;
      while (!server.output.join("").includes("split:") && Date.now() < deadline) {
        await new Promise((resolveDelay) => setTimeout(resolveDelay, 100));
      }
      const output = server.output.join("");
      assert.match(output, /split: café done/);
      assert.doesNotMatch(output, /split: caf\n/);
    });

    test("Durable Object RPC and fetch share the object's storage", async () => {
      const first = await request("/counter/increment");
      assertNotCrashed(first, "/counter/increment");
      assert.equal(first.body, "1");

      const second = await request("/counter/increment");
      assert.equal(second.body, "2");

      const current = await request("/counter");
      assertNotCrashed(current, "/counter");
      assert.equal(current.response.status, 200);
      assert.equal(current.body, "2");
    });

    test("concurrent async requests each complete", async () => {
      const expected = createHash("sha256").update("hello").digest("hex");
      const results = await Promise.all(Array.from({ length: 20 }, () => request("/digest")));
      for (const result of results) {
        assertNotCrashed(result, "/digest");
        assert.equal(result.body, expected);
      }
    });
  });
}
