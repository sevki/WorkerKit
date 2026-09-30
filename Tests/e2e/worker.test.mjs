// End-to-end tests: serve the output of `swift package worker-build`
// (worker.mjs + WorkerKit.wasm, from Sources/HelloWorker) with real workerd
// and celld processes and send HTTP requests to them.
//
//   WORKER_DIR    directory holding the built worker (default: build/worker).
//                 When it is set, a missing build fails instead of skipping.
//   HELLO_CLI     the native HelloWorkerCLI binary (default:
//                 .build/debug/HelloWorkerCLI, from `swift build`); its
//                 tests skip when it is missing.
//   E2E_RUNTIMES  see harness.mjs.

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { runtimes, serve } from "./harness.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const workerDirectory = resolve(root, process.env.WORKER_DIR ?? "build/worker");
const built = existsSync(join(workerDirectory, "WorkerKit.wasm"));
const cli = resolve(root, process.env.HELLO_CLI ?? ".build/debug/HelloWorkerCLI");
const cliSkip = !existsSync(cli) && `no HelloWorkerCLI at ${cli}; run swift build`;

for (const runtime of runtimes) {
  const skip = !built && !process.env.WORKER_DIR
    && `no built worker in ${workerDirectory}; run swift package worker-build`;

  describe(`Swift worker on ${runtime}`, { skip }, () => {
    let server;

    before(async () => {
      server = await serve(runtime, {
        "worker.mjs": await readFile(join(workerDirectory, "worker.mjs")),
        "WorkerKit.wasm": await readFile(join(workerDirectory, "WorkerKit.wasm")),
      }, "WorkerKit.wasm", {
        vars: { GREETING: "hello from env" },
        durableObjects: {
          COUNTER: "Counter", FORKS: "ForkObject", PHILOSOPHERS: "PhilosopherObject", ECHO: "EchoSocket",
          RPCGATEWAY: "RPCGateway",
        },
        kvNamespaces: { KV: "workerkit-e2e-kv" },
        r2Buckets: { R2: "workerkit-e2e-r2" },
        selfBinding: "SELF",
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

    test("Request.cf decodes the cf blob workerd attaches to the request", { skip: runtime !== "workerd" }, async () => {
      const cf = { asn: 13335, asOrganization: "Cloudflare, Inc.", country: "US", colo: "SJC" };
      const result = await request("/cf", { headers: { "Cf-Blob": JSON.stringify(cf) } });
      assertNotCrashed(result, "/cf");
      assert.equal(result.body, "asn=13335\nasOrganization=Cloudflare, Inc.\ncountry=US\ncolo=SJC");
    });

    test("Request.cf with no cf data attached", async () => {
      const result = await request("/cf");
      assertNotCrashed(result, "/cf");
      // workerd reports no cf object at all without a configured cfBlobHeader;
      // celld's local dev emulation gives a cf object with every field empty.
      const expected = runtime === "workerd" ? "no cf" : "asn=\nasOrganization=\ncountry=\ncolo=";
      assert.equal(result.body, expected);
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

    test("stdout without a final newline is logged when the request finishes", { skip: runtime !== "workerd" }, async () => {
      const result = await request("/log-unterminated");
      assertNotCrashed(result, "/log-unterminated");
      const deadline = Date.now() + 5_000;
      while (!server.output.join("").includes("unterminated output") && Date.now() < deadline) {
        await new Promise((resolveDelay) => setTimeout(resolveDelay, 100));
      }
      assert.match(server.output.join(""), /unterminated output/);
    });

    test("a top-level @RPC function is callable through a service binding", async () => {
      const result = await request("/rpc/add");
      assertNotCrashed(result, "/rpc/add");
      assert.equal(result.body, "5");
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

    test("Durable Object SQL storage: state.storage.sql across calls", async () => {
      const first = await request("/counter/sql");
      assertNotCrashed(first, "/counter/sql");
      assert.equal(first.body, "1");

      const second = await request("/counter/sql");
      assertNotCrashed(second, "/counter/sql");
      assert.equal(second.body, "2");
    });

    test("Durable Object WebSocket hibernation: acceptWebSocket + webSocketMessage echoes with an attachment-backed counter", async () => {
      const url = new URL(server.baseURL);
      url.protocol = "ws:";
      url.pathname = "/ws/echo";
      const socket = new WebSocket(url);
      const messages = [];
      socket.addEventListener("message", (event) => messages.push(event.data));

      await new Promise((resolveOpen, reject) => {
        socket.addEventListener("open", resolveOpen, { once: true });
        socket.addEventListener("error", reject, { once: true });
      });

      async function waitForMessage(index) {
        const deadline = Date.now() + 5_000;
        while (messages.length <= index && Date.now() < deadline) {
          await new Promise((resolveDelay) => setTimeout(resolveDelay, 20));
        }
        assert.ok(messages.length > index, `no message #${index} within 5s, got ${JSON.stringify(messages)}`);
        return messages[index];
      }

      socket.send("hello");
      assert.equal(await waitForMessage(0), "1: hello");

      // The running count comes from WebSocket.serializeAttachment/
      // deserializeAttachment, not a Swift instance variable — proof the
      // attachment itself round-trips, which is what would keep it correct
      // across a real hibernation eviction between messages.
      socket.send("again");
      assert.equal(await waitForMessage(1), "2: again");

      await new Promise((resolveClose) => {
        socket.addEventListener("close", resolveClose, { once: true });
        socket.close(1000, "done");
      });
    });

    test("distributed actor over Workers RPC: Doubler.double(_:) through SELF", async () => {
      const result = await request("/distributed/double/21");
      assertNotCrashed(result, "/distributed/double/21");
      assert.equal(result.response.status, 200);
      assert.equal(result.body, "42");
    });

    test("distributed actor over Workers RPC: generic Doubler.echo(_:) through SELF", async () => {
      const result = await request("/distributed/echo", { method: "POST", body: "hello distributed" });
      assertNotCrashed(result, "/distributed/echo");
      assert.equal(result.response.status, 200);
      assert.equal(result.body, "hello distributed");
    });

    test("distributed actor over Workers RPC: Int64 survives as a JS BigInt, not a rounded Double", async () => {
      const result = await request("/distributed/bignumber");
      assertNotCrashed(result, "/distributed/bignumber");
      assert.equal(result.response.status, 200);
      assert.equal(result.body, "match");
    });

    test("distributed actor over Workers RPC: [Int64] stays lossless too, not just a scalar Int64", async () => {
      const result = await request("/distributed/bignumbers");
      assertNotCrashed(result, "/distributed/bignumbers");
      assert.equal(result.response.status, 200);
      assert.equal(result.body, "match");
    });

    test("distributed actor over Workers RPC: superEncoder()/superEncoder(forKey:) keep base-class fields", async () => {
      const result = await request("/distributed/dog");
      assertNotCrashed(result, "/distributed/dog");
      assert.equal(result.response.status, 200);
      assert.equal(result.body, "Rex is a Labrador");
    });

    // The native CLI and the wasm worker are separately compiled binaries:
    // these only pass if both mangle Doubler's distributed methods the same.
    async function runCLI(...args) {
      const { stdout } = await promisify(execFile)(cli, [server.baseURL, ...args], { timeout: 10_000 });
      return stdout.trim();
    }

    test("native CLI: Doubler.double(_:) from a separate host binary", { skip: cliSkip }, async () => {
      assert.equal(await runCLI("double", "21"), "42");
    });

    test("native CLI: generic Doubler.echo(_:) from a separate host binary", { skip: cliSkip }, async () => {
      assert.equal(await runCLI("echo", "hello from the CLI"), "hello from the CLI");
    });

    test("dining philosophers: one concurrent round never deadlocks", async () => {
      const result = await request("/dining/round");
      assertNotCrashed(result, "/dining/round");
      assert.equal(result.response.status, 200);
      const lines = result.body.split("\n");
      assert.equal(lines.length, 5);
      for (const line of lines) {
        assert.match(line, /^phil-\d: (ate \(meal #\d+\)|starved this round .*)$/);
      }
    });

    test("dining philosophers: 30 concurrent rounds make progress with no deadlock", async () => {
      const result = await request("/dining/simulate");
      assertNotCrashed(result, "/dining/simulate");
      assert.equal(result.response.status, 200);
      const totals = result.body.split(",").map(Number);
      assert.equal(totals.length, 5);
      assert.ok(totals.every((n) => Number.isInteger(n) && n >= 0), `expected 5 non-negative integers, got ${result.body}`);
      const sum = totals.reduce((a, b) => a + b, 0);
      assert.ok(sum > 0, `expected some meals to have been eaten across 30 rounds, got ${result.body}`);
      assert.ok(totals.every((n) => n > 0), `expected every philosopher to eat at least once (no starvation), got ${result.body}`);
    });

    test("KV put, getWithMetadata and delete", async () => {
      const put = await request("/kv/greeting", { method: "PUT", body: "hello kv" });
      assertNotCrashed(put, "PUT /kv/greeting");
      assert.equal(put.response.status, 201);

      const get = await request("/kv/greeting");
      assertNotCrashed(get, "GET /kv/greeting");
      assert.equal(get.response.status, 200);
      assert.equal(get.body, "hello kv");
      assert.deepEqual(JSON.parse(get.response.headers.get("x-metadata")), { by: "swift" });

      const deleted = await request("/kv/greeting", { method: "DELETE" });
      assertNotCrashed(deleted, "DELETE /kv/greeting");
      assert.equal(deleted.response.status, 204);
      assert.equal((await request("/kv/greeting")).response.status, 404);
    });

    test("KV get of a missing key returns nil", async () => {
      const result = await request("/kv/missing");
      assert.equal(result.response.status, 404);
      assert.equal(result.body, "Not Found");
    });

    test("KV list pages through keys by prefix", async () => {
      for (const key of ["list/b", "list/a", "other"]) {
        assert.equal((await request(`/kv/${key}`, { method: "PUT", body: key })).response.status, 201);
      }

      const all = await request("/kv?prefix=list/");
      assertNotCrashed(all, "/kv?prefix=list/");
      assert.equal(all.body, "list/a,list/b");
      assert.equal(all.response.headers.get("x-list-complete"), "true");

      const first = await request("/kv?prefix=list/&limit=1");
      assert.equal(first.body, "list/a");
      assert.equal(first.response.headers.get("x-list-complete"), "false");
      const cursor = first.response.headers.get("x-cursor");
      assert.ok(cursor);

      const second = await request(`/kv?prefix=list/&limit=1&cursor=${encodeURIComponent(cursor)}`);
      assertNotCrashed(second, "/kv with a cursor");
      assert.equal(second.body, "list/b");
    });

    test("KV stores and reads bytes", async () => {
      const bytes = new Uint8Array([0, 255, 1, 128, 0xc3]);
      const result = await fetch(`${server.baseURL}/kv-bytes`, { method: "POST", body: bytes });
      assert.equal(result.status, 200);
      assert.deepEqual(new Uint8Array(await result.arrayBuffer()), bytes);
    });

    test("R2 put, get and delete", async () => {
      const put = await request("/r2/greeting", { method: "PUT", body: "hello r2" });
      assertNotCrashed(put, "PUT /r2/greeting");
      assert.equal(put.response.status, 201);

      const get = await request("/r2/greeting");
      assertNotCrashed(get, "GET /r2/greeting");
      assert.equal(get.response.status, 200);
      assert.equal(get.body, "hello r2");
      assert.equal(get.response.headers.get("x-custom-metadata"), "swift");

      const deleted = await request("/r2/greeting", { method: "DELETE" });
      assertNotCrashed(deleted, "DELETE /r2/greeting");
      assert.equal(deleted.response.status, 204);
      assert.equal((await request("/r2/greeting")).response.status, 404);
    });

    test("R2 get of a missing key returns nil", async () => {
      const result = await request("/r2/missing");
      assert.equal(result.response.status, 404);
      assert.equal(result.body, "Not Found");
    });

    test("R2 list pages through keys by prefix", async () => {
      for (const key of ["list/b", "list/a", "other"]) {
        assert.equal((await request(`/r2/${key}`, { method: "PUT", body: key })).response.status, 201);
      }

      const all = await request("/r2?prefix=list/");
      assertNotCrashed(all, "/r2?prefix=list/");
      assert.equal(all.body, "list/a,list/b");
      assert.equal(all.response.headers.get("x-truncated"), "false");

      const first = await request("/r2?prefix=list/&limit=1");
      assert.equal(first.body, "list/a");
      assert.equal(first.response.headers.get("x-truncated"), "true");
      const cursor = first.response.headers.get("x-cursor");
      assert.ok(cursor);

      const second = await request(`/r2?prefix=list/&limit=1&cursor=${encodeURIComponent(cursor)}`);
      assertNotCrashed(second, "/r2 with a cursor");
      assert.equal(second.body, "list/b");
    });

    test("R2 stores and reads bytes", async () => {
      const bytes = new Uint8Array([0, 255, 1, 128, 0xc3]);
      const result = await fetch(`${server.baseURL}/r2-bytes`, { method: "POST", body: bytes });
      assert.equal(result.status, 200);
      assert.deepEqual(new Uint8Array(await result.arrayBuffer()), bytes);
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
