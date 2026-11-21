import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

const base = new URL("../web/", import.meta.url);
const readWeb = name => readFileSync(new URL(name, base), "utf8");
const [jsPath, wasmPath] = process.argv.slice(2);
if (Boolean(jsPath) !== Boolean(wasmPath) || process.argv.length > 4) {
  throw new Error("Usage: node tools/playground-engine-smoke.mjs [engine.js raw.wasm]");
}
const jsEngine = { crypto: globalThis.crypto };
runInNewContext(jsPath ? readFileSync(jsPath, "utf8") : readWeb("engine.js"), jsEngine);
if (!wasmPath) runInNewContext(readWeb("engine-wasm.js"), jsEngine);
const bytes = wasmPath ? readFileSync(wasmPath) : Buffer.from(jsEngine.moonWasmBuild.base64, "base64");
const { instance } = await WebAssembly.instantiate(bytes, {}, {
  builtins: ["js-string"], importedStringConstants: "_",
});
const engines = [["JS", jsEngine], ["Wasm GC", instance.exports]];
const fixtures = runInNewContext(
  readWeb("examples.js") + "\n" + readWeb("lab-tools.js") +
  "\n;({ writeFileInput, mcpRegistry, labFixtures, moonbitSnippet, cliSnippet })",
);
const registry = JSON.stringify(fixtures.mcpRegistry);
const allowed = fixtures.labFixtures.find(({ label }) => label === "MCP tools/call").input;
const rejected = fixtures.labFixtures.find(({ label }) => label === "MCP invalid params").input;
const allowedFrames = [];
const rejectedFrames = [];

for (const [name, engine] of engines) {
  const a = JSON.parse(engine.moonLabGuardMcp(allowed, registry, false, false, false));
  const b = JSON.parse(engine.moonLabGuardMcp(rejected, registry, false, true, false));
  assert.equal(a.forward, true);
  assert.match(a.frame, /"id":9007199254740993(?=[,}])/);
  assert.equal(JSON.parse(a.frame).params.arguments.content, "hello from MoonBit");
  assert.equal(b.forward, false);
  assert.equal(b.error_code, -32602);
  assert.match(b.frame, /"id":9007199254740993(?=[,}])/);
  assert.ok(JSON.parse(b.frame).error.data.issues.some(issue => issue.path.startsWith("$.params.arguments")));
  allowedFrames.push(a);
  rejectedFrames.push(b);
  const input = fixtures.writeFileInput;
  const envelope = JSON.parse(engine.moonLabRun(input, "", false, false, false, false));
  assert.equal(envelope.ok, true);
  const report = JSON.parse(envelope.blocks[0].report.json);
  assert.equal(report.tool, "write_file");
  assert.equal(Buffer.byteLength(report.args.content), 50_000);
  const counts = [];
  for (const width of [64, 256]) {
    engine.moonLabBenchStart();
    let count = 0;
    for (let offset = 0; offset < input.length; offset += width) {
      const chunk = input.slice(offset, offset + width);
      assert.ok(engine.moonLabBenchStep(chunk, false));
      assert.ok(engine.moonLabBenchStep(chunk, true));
      assert.ok(engine.moonLabBenchMatches(), name + " snapshot mismatch at offset " + offset);
      count++;
    }
    assert.ok(engine.moonLabBenchFinish());
    counts.push(width + " units: " + count + " matched snapshots");
  }
  console.log(name + " · 50,000 code bytes · " + counts.join(" · "));
}

assert.deepEqual(allowedFrames[0], allowedFrames[1]);
assert.deepEqual(rejectedFrames[0], rejectedFrames[1]);
for (const [, engine] of engines) engine.moonLabStreamStart(false, false);
let sharedFrames = 0;
for (let offset = 0; offset < fixtures.writeFileInput.length; offset += 256) {
  const end = Math.min(offset + 256, fixtures.writeFileInput.length);
  const chunk = fixtures.writeFileInput.slice(offset, end);
  const prefix = fixtures.writeFileInput.slice(0, end);
  const frames = engines.map(([, engine]) => {
    assert.ok(engine.moonLabStreamPush(chunk));
    return engine.moonLabStreamView(prefix, "", false, false, end === fixtures.writeFileInput.length);
  });
  assert.equal(frames[0], frames[1], "Browser bridge wire mismatch at source unit " + end);
  sharedFrames++;
}
console.log("Exact browser bridge wire conformance · " + sharedFrames + " shared checkpoints");

const flags = { json5: true, coerce: true, extract: false, ignoreThink: true, mcp: true };
const escaped = fixtures.cliSnippet(allowed, registry, flags);
assert.match(escaped, /--mcp-guard --tool-schemas \$labSchema --strict-exit --ignore-think --json5 --coerce/);
assert.match(escaped, /path:''notes\.md''/);
const code = fixtures.moonbitSnippet(allowed, registry, flags);
assert.match(code, /guard_mcp_tool_call\(source, registry, policy~, coerce=true\)/);
const extraction = fixtures.moonbitSnippet(allowed, registry, { ...flags, mcp: false, extract: true });
assert.match(extraction, /extract_all_with_policy\(source, policy\)/);
assert.match(extraction, /coerce_with_schema\(report.value, schema,/);
console.log("MCP exact wire form and audit agreed across both engines. Generated snippets reflect the active options.");
