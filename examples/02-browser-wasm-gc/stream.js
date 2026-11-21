"use strict";

const chunks = ['{"tool":"write_', 'file","args":{"id":', "9007199254740993", ',"path":"report.md'];

async function loadWasmRepair(carrier = globalThis.moonWasmBuild) {
  const binary = Uint8Array.from(atob(carrier.base64), char => char.charCodeAt(0));
  const { instance } = await WebAssembly.instantiate(binary, {}, {
    builtins: ["js-string"],
    importedStringConstants: "_",
  });
  return instance.exports;
}

function* repairChunked(runtime, sourceChunks) {
  runtime.moonLabStreamStart(false, false);
  let prefix = "";
  for (const [index, chunk] of sourceChunks.entries()) {
    const started = performance.now();
    if (!runtime.moonLabStreamPush(chunk)) throw new Error("The input limit was exceeded.");
    prefix += chunk;
    // Read the envelope only. Keep report.json as text to preserve wide integers.
    const frame = JSON.parse(runtime.moonLabStreamView(prefix, "", false, false, index === sourceChunks.length - 1));
    yield { frame, elapsedMs: performance.now() - started };
  }
}

if (typeof document === "object") {
  const run = document.querySelector("#run");
  const output = document.querySelector("#output");
  const status = document.querySelector("#status");
  let engine;
  run.addEventListener("click", async () => {
    run.disabled = true;
    output.textContent = "";
    status.textContent = "Loading local Wasm GC…";
    try {
      engine ??= await loadWasmRepair();
      let index = 0;
      for (const { frame, elapsedMs } of repairChunked(engine, chunks)) {
        index++;
        output.textContent = frame.ok ? frame.blocks[0].report.json : frame.error.message;
        status.textContent = index + "/" + chunks.length + " chunks · " + elapsedMs.toFixed(2) + " ms";
        await new Promise(resolve => setTimeout(resolve, 150));
      }
    } catch (error) {
      status.textContent = "Wasm GC with JS string builtins is required. " + error.message;
    } finally {
      run.disabled = false;
    }
  });
}
