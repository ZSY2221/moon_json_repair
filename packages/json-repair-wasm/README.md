# MoonBit JSON Repair for JavaScript and TypeScript

The ESM SDK calls the compiled MoonBit Wasm GC module directly. It uses no
third-party runtime dependencies. Use Node 22.19+ or a browser with Wasm GC
and the JS string builtins enabled. The same Wasm artifact is built by the
bilingual playground.

## Run from a checkout

```sh
node packages/json-repair-wasm/build.mjs
node --test packages/json-repair-wasm/index.test.mjs
node examples/02-ts-wasm-gc-sdk/main.mts
```

```js
import { createRepairEngine } from "./packages/json-repair-wasm/index.mjs";

const engine = await createRepairEngine();
const result = engine.repair('<think>Draft</think>\n{"order_id":9007199254740993', {
  ignoreThink: true,
});
if (result.ok) console.log(result.blocks[0].output);
// {"order_id":9007199254740993}
```

With the local tarball installed, replace the import specifier with
`@zsy2221/json-repair-wasm`. For browser deployments, serve both
`index.mjs` and `engine.wasm` at their relative URLs. To preload or host the
binary separately, pass `{ wasm: urlOrBytes }` to `createRepairEngine()`.
A `WebAssembly.Module` can also be passed after compiling it with
`{ builtins: ["js-string"], importedStringConstants: "_" }`.
An import from a local offline server uses the same caller and makes no
third-party requests.

## API

| Call | Result |
| --- | --- |
| `repair(source, options?)` | A single repaired block or a structured error |
| `extractAll(source, options?)` | An array of blocks with original source spans |
| `createStream(options?)` | An independent `push`, `preview`, `nextPatches`, `finalize`, and `close` session |
| `guardMcpToolCall(source, registryJson, options?)` | A forwarding decision and exact JSON-RPC wire text, or a registry error |

Supply Schema and registries as JSON text to retain exact numeric limits.
Repair options include `json5`, `ignoreThink`, basic `coerce`, opt-in
`semantic` and `diagnostics`, and diagnostic `language: "en" | "zh"`.
Check `block.validation` before acting on a repaired tool call.
The patch trace describes repaired values before schema coercion.

```js
const stream = engine.createStream();
try {
  for (const chunk of ['{"order_id":', '9007199254740993}']) {
    const accepted = stream.push(chunk);
    if (!accepted.ok) throw new Error(accepted.error.message);
    const frame = stream.nextPatches();
    if (frame.ok) console.log(frame.blocks[0].trace.patches_json);
  }
  const result = stream.finalize();
  if (result.ok) console.log(result.blocks[0].report.json);
} finally {
  stream.close();
}
```

Each stream owns its baseline. Start applying patches from JSON `null`.
`preview()` leaves the baseline alone. `finalize()` frees retained
Wasm state and keeps the final result available via `preview()`. An
abandoned stream should be closed explicitly.

## Exact numbers and sending wire JSON

A canonical safe integer is decoded as a JavaScript `number`. Other
numbers, including wide integers, decimals, exponent forms and `-0`, are
`ExactJsonNumber` instances. Read `.source` for the original lexeme. The
reported `json` and `output`, `trace.patches_json`, MCP `frame`, and each
result's `wire` are already serialized losslessly. Use those strings when
sending JSON on the wire.

## Local tarball

`npm pack ./packages/json-repair-wasm` runs the MoonBit build before
assembling the local SDK tarball. It includes the ESM entry point,
declarations, license, and Wasm binary. The remote package can be released
separately from the Mooncakes library.
