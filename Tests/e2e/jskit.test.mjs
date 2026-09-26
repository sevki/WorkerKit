// End-to-end tests for the JavaScriptKit worker (Examples/JavaScriptKitWorker).
//
//   JSKIT_WORKER_DIR  directory holding the bundled worker.mjs and
//                     JSKitWorker.wasm (see bundle.mjs). The suite is skipped
//                     without it.
//   E2E_RUNTIMES      see harness.mjs.

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { runtimes, serve } from "./harness.mjs";

const workerDirectory = process.env.JSKIT_WORKER_DIR;

for (const runtime of runtimes) {
  describe(`JavaScriptKit worker on ${runtime}`, { skip: !workerDirectory && "JSKIT_WORKER_DIR is not set" }, () => {
    let server;

    before(async () => {
      server = await serve(runtime, {
        "worker.mjs": await readFile(join(workerDirectory, "worker.mjs")),
        "JSKitWorker.wasm": await readFile(join(workerDirectory, "JSKitWorker.wasm")),
      }, "JSKitWorker.wasm");
    });

    after(async () => {
      await server?.stop();
    });

    async function request(path, init) {
      const response = await fetch(`${server.baseURL}${path}`, init);
      const body = await response.text();
      assert.notEqual(response.status, 500, `unexpected 500 for ${path}: ${body}\n${server.output.join("")}`);
      return { response, body };
    }

    test("GET / builds a Response in Swift", async () => {
      const { response, body } = await request("/");
      assert.equal(response.status, 200);
      assert.equal(body, "Hello from JavaScriptKit on workerd/celld");
      assert.equal(response.headers.get("content-type"), "text/plain; charset=utf-8");
    });

    test("GET /digest awaits crypto.subtle from Swift", async () => {
      const { response, body } = await request("/digest");
      assert.equal(response.status, 200);
      assert.equal(body, createHash("sha256").update("hello").digest("hex"));
    });

    test("GET /headers reads the Request's headers", async () => {
      const { response, body } = await request("/headers", { headers: { "x-echo": "swift" } });
      assert.equal(body, "swift");
      assert.equal(response.headers.get("x-echo"), "swift");
    });

    test("an unknown path returns 404", async () => {
      const { response } = await request("/missing");
      assert.equal(response.status, 404);
    });

    test("concurrent async requests each complete", async () => {
      const expected = createHash("sha256").update("hello").digest("hex");
      const results = await Promise.all(Array.from({ length: 20 }, () => request("/digest")));
      for (const { body } of results) {
        assert.equal(body, expected);
      }
    });
  });
}
