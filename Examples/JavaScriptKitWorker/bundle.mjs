// Usage: node bundle.mjs <JavaScriptKit runtime.mjs> <JSKitWorker.wasm> <output dir>
//
// Writes <output dir>/worker.mjs (runtime.mjs + shim.mjs in one module) and
// <output dir>/JSKitWorker.wasm.
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [runtimePath, wasmPath, outputDirectory] = process.argv.slice(2);
if (!runtimePath || !wasmPath || !outputDirectory) {
  console.error("usage: node bundle.mjs <runtime.mjs> <JSKitWorker.wasm> <output dir>");
  process.exit(2);
}

const runtime = await readFile(runtimePath, "utf8");
const exportLine = /^export \{ SwiftRuntime \};\s*$/m;
if (!exportLine.test(runtime)) {
  throw new Error(`${runtimePath} no longer ends with "export { SwiftRuntime };"`);
}
const shim = await readFile(join(dirname(fileURLToPath(import.meta.url)), "shim.mjs"), "utf8");

await mkdir(outputDirectory, { recursive: true });
await writeFile(join(outputDirectory, "worker.mjs"), `${runtime.replace(exportLine, "")}\n${shim}`);
await copyFile(wasmPath, join(outputDirectory, "JSKitWorker.wasm"));
