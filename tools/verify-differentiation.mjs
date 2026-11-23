import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { cpus, homedir, tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";
import { ExactJsonNumber, createRepairEngine } from "../packages/json-repair-wasm/index.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const args = process.argv.slice(2);
const outputFlag = args.indexOf("--output");
const timing = !args.includes("--no-timing");
const checkDoc = args.includes("--check-doc");
const output = outputFlag < 0 ? join(root, "_build", "differentiation") : resolve(args[outputFlag + 1] ?? "");
if (outputFlag >= 0) {
  assert.ok(args[outputFlag + 1] && !args[outputFlag + 1].startsWith("--"), "--output requires a directory");
  args.splice(outputFlag, 2);
}
assert.ok(new Set(args).size === args.length && args.every(arg => ["--no-timing", "--check-doc"].includes(arg)),
  "Usage: node tools/verify-differentiation.mjs [--no-timing] [--check-doc] [--output DIRECTORY]");
assert.equal(typeof JSON.rawJSON, "function", "Node 22+ with JSON.rawJSON is required for exact patch replay");

const read = path => readFileSync(join(root, path), "utf8");
const digest = source => createHash("sha256").update(source).digest("hex");
const save = (name, value) => writeFileSync(join(output, name), value);
const wide = "9007199254740993";
const manifest = read("moon.mod");
const version = manifest.match(/^version\s*=\s*"([^"]+)"/m)?.[1];
const moduleName = manifest.match(/^name\s*=\s*"([^"]+)"/m)?.[1];
assert.ok(version && moduleName);
const vm = { crypto: globalThis.crypto };
const jsSource = read("web/engine.js");
runInNewContext(jsSource, vm);
runInNewContext(read("web/engine-wasm.js"), vm);
assert.equal(vm.moonWasmBuild.version, version, "Rebuild browser assets with node web/build.mjs");
const wasmBytes = Buffer.from(vm.moonWasmBuild.base64, "base64");
const wasm = await createRepairEngine({ wasm: wasmBytes });
const binary = await WebAssembly.instantiate(wasmBytes, {}, {
  builtins: ["js-string"], importedStringConstants: "_",
});
const engines = [["JS", vm], ["Wasm GC", binary.instance.exports]];
assert.deepEqual(WebAssembly.Module.imports(binary.module), []);

function dual(method, parameters) {
  const [js, wasm] = engines.map(([, engine]) => engine[method](...parameters));
  assert.equal(wasm, js, method + " results differ");
  return JSON.parse(wasm);
}

// Convert every numeric value into a stable source-aware JS representation.
// Safe integers remain numbers. Other forms retain their verbatim lexemes.
function parseExact(text) {
  return JSON.parse(text, (_key, value, context) => {
    if (typeof value !== "number" || (Number.isSafeInteger(value) && String(value) === context.source)) return value;
    return new ExactJsonNumber(context.source);
  });
}

function stringifyExact(value, space) {
  return JSON.stringify(value, (_key, item) =>
    item instanceof ExactJsonNumber ? JSON.rawJSON(item.source) : item, space);
}

function replay(value, patches) {
  for (const patch of patches) {
    assert.ok(["add", "replace", "remove"].includes(patch.op), "unexpected patch operation " + patch.op);
    if (patch.path === "") {
      value = patch.op === "remove" ? null : patch.value;
      continue;
    }
    assert.ok(patch.path.startsWith("/"));
    const path = patch.path.slice(1).split("/").map(key => key.replaceAll("~1", "/").replaceAll("~0", "~"));
    const parent = path.slice(0, -1).reduce((node, key) => {
      assert.ok(Object.hasOwn(node, key), "missing pointer parent: " + patch.path);
      return node[key];
    }, value);
    const key = path.at(-1);
    if (Array.isArray(parent)) {
      const index = key === "-" ? parent.length : Number(key);
      assert.ok(Number.isInteger(index) && index >= 0 && index <= parent.length);
      if (patch.op === "add") parent.splice(index, 0, patch.value);
      else if (patch.op === "remove") parent.splice(index, 1);
      else parent[index] = patch.value;
    } else if (patch.op === "remove") {
      assert.ok(Object.hasOwn(parent, key));
      delete parent[key];
    } else {
      if (patch.op === "replace") assert.ok(Object.hasOwn(parent, key));
      Object.defineProperty(parent, key, { value: patch.value, enumerable: true, configurable: true, writable: true });
    }
  }
  return value;
}

const thinkInput = [
  "<ThInK>",
  '{"tool":"discard_me","args":{"account":7}}',
  '<think>{"tool":"nested_decoy"}</think>',
  "</tHiNk>",
  '{"tool":"get_balance","args":{"id":' + wide + ',"note":"Literal <think>keep</think>"}}',
  '{"tool":"send_notice","args":{"message":"Ready 🌙',
].join("\r\n");
const schemaInput = [
  "{", '  "userName": "Ada",', '  "currency": "usd",', '  "order_id": "' + wide + '",', '  "amount": -25', "}",
].join("\r\n");
const schemaValue = {
  type: "object",
  required: ["user_name", "currency", "order_id", "amount"],
  properties: {
    user_name: { type: "string" },
    currency: { type: "string", enum: ["USD", "EUR"] },
    order_id: { type: "integer" },
    amount: { type: "integer", minimum: 1 },
  },
};
const schemaText = JSON.stringify(schemaValue, null, 2);
const mcpInput = read("examples/03-mcp-guard-pipeline/requests.ndjson").replaceAll("\r\n", "\n");
const registry = read("examples/03-mcp-guard-pipeline/tools.json").replaceAll("\r\n", "\n");

function writeFileFixture() {
  // Keep the workload source in one place with the native MoonBit benchmark.
  const source = read("incremental_bench_test.mbt");
  const parts = ["head", "line", "tail"].map(name => source.match(new RegExp("let " + name + "\\s*=\\s*#\\|([^\\r\\n]+)"))?.[1]);
  assert.ok(parts.every(Boolean), "Cannot read the MoonBit benchmark fixture");
  const [head, line, tail] = parts;
  const contentBytes = 50_000 - head.length - tail.length;
  const payload = head + line.repeat(Math.floor(contentBytes / line.length)) + " ".repeat(contentBytes % line.length) + tail;
  assert.equal(Buffer.byteLength(payload), 50_000);
  assert.equal(parseExact(payload).args.id.source, wide);
  return payload;
}

function providerFixture() {
  const event = (id, choices) => "data: " + JSON.stringify({ id, choices }) + "\r\n\r\n";
  const delta = (toolCalls, extra = {}) => ({ index: 0, delta: { ...extra, tool_calls: toolCalls } });
  const first = (index, id, name, data) => ({ index, id, type: "function", function: { name, arguments: data } });
  const next = (index, data) => ({ index, function: { arguments: data } });
  return [
    event("chatcmpl-proof", [delta([], { reasoning_content: '{"tool":"discard_reasoning"}' })]),
    event("chatcmpl-proof", [delta([
      first(0, "call-good", "create_invoice", '<think>{draft:true}</think>{"order_id":'),
      first(1, "call-bad", "create_invoice", '{"order_id":'),
    ])]),
    event("chatcmpl-proof", [delta([
      next(1, wide + ',"currency":"USD","amount_cents":-25}'),
      next(0, wide + ',"currency":"USD","amount_cents":"1250"'),
    ])]),
    event("chatcmpl-proof", [{ index: 0, delta: {}, finish_reason: "tool_calls" }]),
    "data: [DONE]\r\n\r\n",
  ].join("");
}

function anthropicFixture() {
  const event = (type, fields = {}) => "event: " + type + "\r\ndata: " + JSON.stringify({ type, ...fields }) + "\r\n\r\n";
  const start = (index, id) => event("content_block_start", {
    index, content_block: { type: "tool_use", id, name: "create_invoice", input: {} },
  });
  const delta = (index, partial_json) => event("content_block_delta", { index, delta: { type: "input_json_delta", partial_json } });
  return [
    event("message_start", { message: { id: "msg-proof" } }),
    event("content_block_start", { index: 0, content_block: { type: "thinking", thinking: "" } }),
    event("content_block_delta", { index: 0, delta: { type: "thinking_delta", thinking: '{"tool":"discard_reasoning"}' } }),
    event("content_block_stop", { index: 0 }),
    start(1, "call-good"),
    delta(1, '<think>{draft:true}</think>{"order_id":'),
    delta(1, wide + ',"currency":"USD","amount_cents":"1250"'),
    event("content_block_stop", { index: 1 }),
    start(2, "call-bad"),
    delta(2, '{"order_id":'),
    delta(2, wide + ',"currency":"USD","amount_cents":-25}'),
    event("content_block_stop", { index: 2 }),
    event("message_stop"),
  ].join("");
}

const streamInput = writeFileFixture();
const sseInput = providerFixture();
const anthropicInput = anthropicFixture();
mkdirSync(output, { recursive: true });
const fixtures = {
  "01-think.txt": thinkInput,
  "02-schema-input.json": schemaInput,
  "02-schema.json": schemaText,
  "03-write-file.txt": streamInput,
  "04-mcp.ndjson": mcpInput,
  "04-tools.json": registry,
  "04-provider.sse": sseInput,
  "04-anthropic.sse": anthropicInput,
};
for (const [name, value] of Object.entries(fixtures)) save(name, value);
console.log("Wrote " + Object.keys(fixtures).length + " comparison fixtures to " + output);

function verifyThink() {
  const off = wasm.extractAll(thinkInput, { diagnostics: true });
  const on = wasm.extractAll(thinkInput, { diagnostics: true, ignoreThink: true });
  for (const [ignore, expected] of [[false, off], [true, on]]) {
    assert.equal(vm.moonLabRunWithOptions(thinkInput, "", false, false, true, ignore, false, true, false), expected.wire);
    assert.ok(expected.ok);
  }
  const names = result => result.blocks.map(block => block.value.tool);
  assert.deepEqual(names(off), ["discard_me", "nested_decoy", "get_balance", "send_notice"]);
  assert.deepEqual(names(on), ["get_balance", "send_notice"]);
  const [balance, notice] = on.blocks;
  assert.equal(balance.value.args.id.source, wide);
  assert.equal(balance.value.args.note, "Literal <think>keep</think>");
  assert.equal(notice.value.args.message, "Ready 🌙");
  const audit = balance.report.edits.find(edit => edit.kind === "ignore_think_block");
  assert.ok(audit && audit.position.offset === 0);
  assert.match(thinkInput.slice(audit.position.offset, audit.end_offset), /<think>.*nested_decoy.*<\/think>[\s\S]*<\/tHiNk>$/u);
  assert.match(notice.diagnostic, /--> 6:50 \(UTF-16\)/);
  const byChunk = new Map();
  const width = 7;
  for (const ignore of [false, true]) {
    for (const [, engine] of engines) engine.moonLabStreamStart(false, ignore);
    const visible = [];
    for (let start = 0; start < thinkInput.length; start += width) {
      const end = Math.min(start + width, thinkInput.length);
      const chunk = thinkInput.slice(start, end);
      for (const [, engine] of engines) assert.ok(engine.moonLabStreamPush(chunk));
      const snapshot = dual("moonLabStreamView", [thinkInput.slice(0, end), "", false, true, end === thinkInput.length]);
      if (end === thinkInput.length) {
        assert.equal(snapshot.stream.finalized, true);
        assert.deepEqual(names(snapshot), names(ignore ? on : off));
      }
      visible.push((snapshot.blocks ?? []).map(block => block.value.tool).filter(Boolean));
    }
    byChunk.set(ignore, visible);
  }
  assert.ok(byChunk.get(false).some(tools => tools.includes("discard_me")));
  assert.ok(byChunk.get(false).some(tools => tools.includes("nested_decoy")));
  assert.ok(byChunk.get(true).every(tools => tools.every(tool => !/^(discard_me|nested_decoy)$/.test(tool))));
  assert.ok(byChunk.get(true).slice(0, -1).some(tools => tools.includes("get_balance")));
  return { isolationOff: names(off), isolationOn: names(on), wireOutputs: on.blocks.map(block => block.output),
    draftAudit: audit, retainedSourceSpans: on.blocks.map(({ start, end }) => ({ start, end })),
    draftDiagnostic: balance.diagnostic,
    transport: { chunkUnits: width, checkpoints: byChunk.get(true).length,
      isolationOff: byChunk.get(false), isolationOn: byChunk.get(true) } };
}

function verifySchema() {
  const strict = wasm.repair(schemaInput, { schema: schemaText, diagnostics: true });
  const base = wasm.repair(schemaInput, { schema: schemaText, diagnostics: true, coerce: true });
  const optIn = wasm.repair(schemaInput, { schema: schemaText, diagnostics: true, semantic: true });
  for (const [coerce, semantic, report] of [[false, false, strict], [true, false, base], [true, true, optIn]]) {
    assert.equal(vm.moonLabRunWithOptions(schemaInput, schemaText, false, coerce, false, false, semantic, true, false), report.wire);
    assert.ok(report.ok);
  }
  const [plain, legacy, recovered] = [strict, base, optIn].map(result => result.blocks[0]);
  assert.deepEqual(plain.validation.errors.map(({ keyword }) => keyword).sort(), ["enum", "minimum", "required", "type"]);
  assert.equal(legacy.validation.errors.length, 3);
  assert.deepEqual(recovered.validation.errors.map(({ path, keyword }) => [path, keyword]), [["$.amount", "minimum"]]);
  assert.deepEqual(recovered.coercions.map(({ path, kind }) => [path, kind]), [
    ["$.user_name", "rename_key"], ["$.currency", "normalize_enum"], ["$.order_id", "string_to_number"],
  ]);
  assert.equal(recovered.value.order_id.source, wide);
  assert.equal(recovered.value.amount, -25);
  assert.match(recovered.output, /"order_id":9007199254740993(?=[,}])/);
  assert.match(recovered.diagnostic, /error\[minimum\][\s\S]*\$\.amount[\s\S]*"amount":-25[\s\S]*\^{3}/u);
  assert.deepEqual(JSON.parse(recovered.retry_prompt.split("\n")[1]).fix, [
    { path: "$.amount", expected: "expected number >= 1", actual: -25, example: 1 },
  ]);
  const conflictValue = { hat: 5, satt: 7, userName: "Ada" };
  const conflictSchema = { properties: { bat: true, cat: true, sat: true, user_name: true } };
  const conflict = dual("moonLabRunWithOptions", [
    JSON.stringify(conflictValue), JSON.stringify(conflictSchema), false, true, false, false, true, true, false,
  ]).blocks[0];
  assert.deepEqual(conflict.validation.errors.map(({ path, keyword }) => [path, keyword]), [
    ["$.hat", "ambiguous_key"], ["$.satt", "key_collision"],
  ]);
  assert.equal(conflict.output, '{"hat":5,"satt":7,"user_name":"Ada"}');
  assert.match(conflict.retry_prompt, /compete for \$\.sat/u);
  return {
    strict: { issues: plain.validation.errors, output: plain.output, diagnostic: plain.diagnostic, retryPrompt: plain.retry_prompt },
    base: { issues: legacy.validation.errors, output: legacy.output },
    semantic: { wireOutput: recovered.output, edits: recovered.coercions, issues: recovered.validation.errors,
      diagnostic: recovered.diagnostic, retryPrompt: recovered.retry_prompt },
    conflict: { input: conflictValue, schema: conflictSchema, wireOutput: conflict.output, issues: conflict.validation.errors, retryPrompt: conflict.retry_prompt },
  };
}

const chunkUnits = 64;
const chunks = Array.from({ length: Math.ceil(streamInput.length / chunkUnits) },
  (_, index) => streamInput.slice(index * chunkUnits, (index + 1) * chunkUnits));

function verifyStream() {
  assert.equal(chunks.length, 782);
  for (const [, engine] of engines) {
    engine.moonLabBenchStart();
    engine.moonLabStreamStart(false, false);
  }
  const seals = new Map();
  let applied = null;
  let prefix = "";
  let totalOperations = 0;
  let firstContent = null;
  let matchingSnapshots = 0;
  let strictReadyChunk = 0;
  for (const [index, chunk] of chunks.entries()) {
    prefix += chunk;
    const final = index + 1 === chunks.length;
    try {
      JSON.parse(prefix);
      strictReadyChunk ||= index + 1;
    } catch (error) {
      assert.ok(error instanceof SyntaxError);
    }
    const frames = engines.map(([name, engine]) => {
      assert.ok(engine.moonLabBenchStep(chunk, false) && engine.moonLabBenchStep(chunk, true));
      assert.ok(engine.moonLabBenchMatches(), name + " benchmark parity at chunk " + (index + 1));
      assert.ok(engine.moonLabStreamPush(chunk));
      return engine.moonLabStreamView(prefix, "", false, false, final);
    });
    assert.equal(frames[0], frames[1], "JS / Wasm GC disagreement at chunk " + (index + 1));
    const result = parseExact(frames[1]);
    assert.ok(result.ok);
    const { trace } = result.blocks[0];
    applied = replay(applied, trace.patches);
    assert.equal(stringifyExact(applied), trace.json, "Patch replay mismatch at chunk " + (index + 1));
    assert.equal(result.stream.finalized, final);
    totalOperations += trace.patches.length;
    matchingSnapshots++;
    for (const { pointer, sealed } of trace.fields) {
      if (pointer === "/args/content" && !sealed && firstContent === null) {
        firstContent = { chunk: index + 1, decodedUnits: applied.args.content.length };
      }
      if (sealed && !seals.has(pointer)) seals.set(pointer, index + 1);
    }
  }
  for (const [, engine] of engines) assert.ok(engine.moonLabBenchFinish());
  assert.equal(stringifyExact(applied), streamInput);
  assert.equal(applied.args.id.source, wide);
  assert.ok(firstContent?.chunk < seals.get("/args/content"));
  assert.ok(seals.get("/args/path") < strictReadyChunk);
  assert.equal(strictReadyChunk, chunks.length);
  return {
    bytes: Buffer.byteLength(streamInput), chunkUnits, matchingSnapshots, totalOperations, strictReadyChunk,
    firstContent, firstSealedChunk: Object.fromEntries([...seals].filter(([pointer]) => pointer !== "")),
    finalTool: applied.tool, finalId: wide,
    finalSha256: digest(stringifyExact(applied)),
  };
}

function timeSameEngine() {
  function timedRun(engine, uncached) {
    engine.moonLabBenchStart();
    const start = performance.now();
    for (const chunk of chunks) engine.moonLabBenchStep(chunk, uncached);
    const elapsed = performance.now() - start;
    // Finalization releases the two lanes. Equality was established by the
    // untimed run, since only one of the lanes is populated here.
    engine.moonLabBenchFinish();
    return elapsed;
  }
  const round = value => Number(value.toFixed(3));
  const median = values => values.sort((a, b) => a - b)[Math.floor(values.length / 2)];
  return engines.map(([backend, engine]) => {
    timedRun(engine, false);
    timedRun(engine, true);
    const samples = [[], []];
    for (let run = 0; run < 7; run++) {
      for (const index of [run % 2, 1 - run % 2]) samples[index].push(timedRun(engine, Boolean(index)));
    }
    const [cached, uncached] = samples.map(median);
    return { backend, cachedMs: round(cached), uncachedMs: round(uncached), speedup: round(uncached / cached) };
  });
}

function moon(args, cwd = root) {
  const options = { cwd, encoding: "utf8", timeout: 120_000 };
  let result = spawnSync("moon", args, options);
  if (result.error?.code === "ENOENT") {
    result = spawnSync(join(homedir(), ".moon", "bin", process.platform === "win32" ? "moon.exe" : "moon"), args, options);
  }
  if (result.error) throw result.error;
  assert.equal(result.status, 0, "moon " + args.join(" ") + "\n" + result.stdout + result.stderr);
  return result.stdout;
}

function runProvider() {
  const scratchParent = realpathSync(tmpdir());
  const prefix = "moon-json-differentiation-";
  const scratch = mkdtempSync(join(scratchParent, prefix));
  try {
    const library = join(scratch, "library");
    const cli = join(library, "cmd", "cli");
    const consumer = join(scratch, "consumer");
    mkdirSync(cli, { recursive: true });
    mkdirSync(consumer);
    for (const [from, to, manifests] of [
      [root, library, ["moon.mod", "moon.pkg", "README.md"]],
      [join(root, "cmd", "cli"), cli, ["moon.pkg"]],
    ]) {
      for (const file of readdirSync(from, { withFileTypes: true })) {
        if (file.isFile() && (manifests.includes(file.name) ||
          (file.name.endsWith(".mbt") && !/_(?:wb)?test\.mbt$/.test(file.name)))) {
          copyFileSync(join(from, file.name), join(to, file.name));
        }
      }
    }
    writeFileSync(join(scratch, "moon.work"), 'members = ["library", "consumer"]\n');
    writeFileSync(join(consumer, "moon.mod"), 'name = "local/sse_proof"\nimport {\n  "' + moduleName + "@" + version + '"\n}\n');
    writeFileSync(join(consumer, "moon.pkg"), `import {
  "${moduleName}/cmd/cli" @cli,
  "moonbitlang/core/encoding/utf8",
}
pkgtype(kind: "executable")
`);
    const flags = '["--sse", "--emit-patches", "--schema", "local", "--coerce", "--ignore-think", "--strict-exit", "--retry-prompt"]';
    const provider = `///|
fn prove_provider(label : String, raw : String) -> Unit {
  let source = @utf8.encode(raw)
  let schema = try! @cli.parse_schema(${JSON.stringify(JSON.stringify(JSON.parse(registry).create_invoice))})
  let options = try! @cli.parse_args(${flags})
  let gateway = @cli.SseGateway::new(options, Some(schema))
  let decoder = @cli.SseDecoder::new(max_chars=100000)
  for start = 0; start < source.length(); {
    let end = (start + 7).min(source.length())
    let chunk = source[start:end]
    for offset = 0; offset < chunk.length(); {
      let (next, item) = decoder.next(chunk, offset)
      if item is Some(record) {
        for item in gateway.consume(record) { println(item.stringify()) }
      }
      continue next
    }
    continue end
  }
  if decoder.finish() is Some(record) {
    for item in gateway.consume(record) { println(item.stringify()) }
  }
  for item in gateway.finish(decoder.line()) { println(item.stringify()) }
  let metadata : Json = { "provider": label, "gateway_status": gateway.exit_status(), "done": gateway.is_done() }
  println(metadata.stringify())
}

///|
fn main {
  prove_provider("openai", ${JSON.stringify(sseInput)})
  prove_provider("anthropic", ${JSON.stringify(anthropicInput)})
}
`;
    writeFileSync(join(consumer, "main.mbt"), provider);
    const outputs = ["js", "wasm-gc"].map(target =>
      moon(["run", "--target", target, "--deny-warn", "consumer"], scratch).trim().split(/\r?\n/));
    assert.deepEqual(outputs[0], outputs[1], "Exact provider NDJSON differed between JS and Wasm GC");
    return outputs[1];
  } finally {
    const resolved = realpathSync(scratch);
    assert.ok(dirname(resolved) === scratchParent && basename(resolved).startsWith(prefix));
    rmSync(resolved, { recursive: true, force: true, maxRetries: 4, retryDelay: 100 });
  }
}

function verifyMcp() {
  const sources = mcpInput.trimEnd().split(/\r?\n/);
  const outcomes = sources.map(source => {
    const result = wasm.guardMcpToolCall(source, registry, { coerce: true });
    assert.equal(vm.moonLabGuardMcp(source, registry, false, true, false), result.wire);
    return result;
  });
  assert.deepEqual(outcomes.map(({ forward }) => forward), [true, true, true, false]);
  assert.equal(outcomes[0].frame, sources[0]);
  assert.equal(outcomes[1].frame, sources[1]);
  const good = parseExact(outcomes[2].frame);
  const reject = JSON.parse(outcomes[3].frame);
  assert.equal(good.params.arguments.order_id.source, wide);
  assert.equal(good.params.arguments.amount_cents, 1250);
  assert.equal(reject.error.code, -32602);
  assert.equal(reject.id, "amount-1");
  assert.ok(reject.error.data.issues.some(({ path }) => path === "$.params.arguments.amount_cents"));
  assert.match(reject.error.data.retry_prompt, /amount_cents/);
  save("04-mcp-output.ndjson", outcomes.map(({ frame }) => frame).join("\n") + "\n");

  const providerWire = runProvider();
  let start = 0;
  const providers = [];
  for (const [index, record] of providerWire.entries()) {
    const meta = JSON.parse(record);
    if (!Object.hasOwn(meta, "gateway_status")) continue;
    providers.push(verifyProvider(providerWire.slice(start, index), meta));
    start = index + 1;
  }
  assert.deepEqual(providers.map(({ provider }) => provider), ["openai", "anthropic"]);
  assert.deepEqual(providers[0].routed, providers[1].routed, "Provider adapters must produce the same MCP routing");
  assert.equal(start, providerWire.length);
  return { direct: outcomes.map(({ forward, frame, audit }) => ({ forward, frame, audit })), providers };
}

function verifyProvider(providerWire, meta) {
  const provider = meta.provider;
  assert.equal(meta.gateway_status, 3);
  assert.ok(meta.done);
  const events = providerWire.map(parseExact);
  const completions = events.filter(record => record.event === "tool_call");
  assert.deepEqual(completions.map(({ call }) => call.id), ["call-good", "call-bad"]);
  assert.deepEqual(completions.map(({ status }) => status), [0, 3]);
  const format = provider === "openai" ? "openai_chat_completions" : "anthropic_messages";
  assert.ok(events.every(event => event.call.provider === format));
  assert.ok(events.every(event => ["patch", "tool_call"].includes(event.event)));
  assert.doesNotMatch(providerWire.join("\n"), /discard_reasoning|draft:true/);
  assert.ok(completions[0].edits.some(edit => edit.kind === "ignore_think_block"));
  assert.match(completions[0].json, /"order_id":9007199254740993(?=[,}])/);
  assert.match(completions[0].json, /"amount_cents":1250/);

  const values = new Map();
  for (const event of events) {
    const id = event.call.id;
    const value = replay(values.get(id) ?? null, event.patches);
    values.set(id, value);
    assert.equal(stringifyExact(value), event.json, "Provider Patch replay for " + id + " sequence " + event.seq);
  }
  const routed = completions.map(record => {
    const raw = '{"jsonrpc":"2.0","id":' + JSON.stringify(record.call.id) +
      ',"method":"tools/call","params":{"name":' + JSON.stringify(record.call.name) + ',"arguments":' + record.json + '}}';
    const result = wasm.guardMcpToolCall(raw, registry, { coerce: true });
    assert.equal(vm.moonLabGuardMcp(raw, registry, false, true, false), result.wire);
    return { call: record.call.id, status: record.status, raw, forward: result.forward, frame: result.frame };
  });
  assert.deepEqual(routed.map(({ forward }) => forward), [true, false]);
  assert.equal(JSON.parse(routed[1].frame).error.code, -32602);
  assert.match(routed[0].frame, /"order_id":9007199254740993/);
  save("04-" + provider + "-output.ndjson", providerWire.join("\n") + "\n");
  return {
    provider, backends: ["JS", "Wasm GC"], implementation: "CLI SseDecoder + SseGateway", transportChunkBytes: 7,
    strictStatus: meta.gateway_status, events: events.length, patches: events.filter(event => event.event === "patch").length, routed,
  };
}

const proof = {
  version,
  backends: engines.map(([name]) => name),
  runtime: { node: process.version, moon: moon(["version"]).trim(), host: process.platform, cpu: cpus()[0]?.model.trim() },
  artifacts: { browserJsSha256: digest(jsSource), browserWasmSha256: digest(wasmBytes) },
  fixtures: Object.fromEntries(Object.entries(fixtures).map(([name, value]) =>
    [name, { bytes: Buffer.byteLength(value), sha256: digest(value) }])),
  nestedThink: verifyThink(),
  schema: verifySchema(),
  writeFile: verifyStream(),
  mcp: verifyMcp(),
};
if (timing) {
  proof.writeFile.timing = {
    iterations: 7,
    work: "Per 64 UTF-16 chunk: push + preview + next_patches; same backend, same policy, median complete-stream elapsed time.",
    rows: timeSameEngine(),
  };
}
save("proof.json", stringifyExact(proof, 2) + "\n");

const code = (language, content) => "\n```" + language + "\n" + content.trimEnd() + "\n```\n";
const evidence = [
  "## Nested reasoning isolation",
  "",
  "Raw input has a mixed-case outer draft, a nested draft, a literal tag in argument text, and a second truncated call.",
  code("text", thinkInput.replaceAll("\r\n", "\n")),
  "Same MoonBit extraction API, same input. With isolation off: " + proof.nestedThink.isolationOff.map(name => "`" + name + "`").join(", ") +
    ". With isolation on: " + proof.nestedThink.isolationOn.map(name => "`" + name + "`").join(", ") + ".",
  "",
  "At " + proof.nestedThink.transport.checkpoints + " checkpoints with " + proof.nestedThink.transport.chunkUnits +
    " UTF-16 units per chunk, the JS and Wasm GC results matched. Both draft tool names appeared with isolation disabled. With isolation enabled, neither appeared on any checkpoint.",
  "",
  "The retained call preserves the exact integer and literal tag, the trailing call is repaired, and the audit marks one outer draft span.",
  code("json", proof.nestedThink.wireOutputs.join("\n")),
  "## Schema recovery",
  "",
  "Raw arguments with a string order ID and a negative integer amount.",
  code("json", schemaInput.replaceAll("\r\n", "\n")),
  "Strict validation emits " + proof.schema.strict.issues.length + " issues and type-only coercion still emits " +
    proof.schema.base.issues.length + ". Semantic opt-in keeps the unquoted exact order ID and leaves the real minimum violation at $.amount.",
  code("json", proof.schema.semantic.wireOutput),
  code("text", proof.schema.semantic.diagnostic),
  code("text", proof.schema.semantic.retryPrompt),
  "The separate tie probe keeps both contested keys and recovers only the independent alias. Its retry prompt names both conflicts.",
  code("text", proof.schema.conflict.retryPrompt),
  "## 50,000-byte write_file stream",
  "",
  "First " + 128 + " bytes of the " + proof.writeFile.bytes + " B input. SHA-256 `" + proof.fixtures["03-write-file.txt"].sha256 + "`.",
  code("text", streamInput.slice(0, 128)),
  proof.writeFile.matchingSnapshots + " matching 64-UTF-16-unit checkpoints across JS / Wasm GC, with " +
    proof.writeFile.totalOperations + " replayed RFC 6902 operations at exact wire precision. " +
    "The path seals at chunk " + proof.writeFile.firstSealedChunk["/args/path"] + ", content begins streaming at chunk " +
    proof.writeFile.firstContent.chunk + " and seals at chunk " + proof.writeFile.firstSealedChunk["/args/content"] +
    ". Strict JSON.parse first succeeds at chunk " + proof.writeFile.strictReadyChunk + ".",
  "",
  "## MCP and provider SSE",
  "",
  "Four raw JSON-RPC frames. The third ends before its two outer braces.",
  code("text", mcpInput.replaceAll("\r\n", "\n")),
  "Identical MCP inputs produce three forwardable frames and one rejected frame with JSON-RPC `-32602`. " +
    "The two legal passthrough frames are unchanged, including the exact request ID.",
  code("json", proof.mcp.direct.slice(2).map(({ frame }) => frame).join("\n")),
  "Synthetic OpenAI Chat Completions and Anthropic Messages transports are fragmented at 7 bytes and decoded by the production `SseDecoder` and `SseGateway` on both backends.",
  "",
  "| SSE format | Patch events replayed by call ID | Completed calls | MCP routing |",
  "| --- | ---: | ---: | --- |",
  ...proof.mcp.providers.map(({ provider, patches, routed }) =>
    "| " + provider + " | " + patches + " | " + routed.length + " | " + routed.filter(record => record.forward).length + " forward, 1 reject |"),
  "",
  "Both provider replays produce the same two MCP wire frames.",
  code("json", proof.mcp.providers[0].routed.map(({ frame }) => frame).join("\n")),
].join("\n").trimEnd();
save("proof-block.md", evidence + "\n");
const md = [
  "# v" + version + " reproducible differentiation", "",
  "Run `node web/build.mjs`, then `node tools/verify-differentiation.mjs`. The adjacent raw inputs and `proof.json` contain hashes and exact wire evidence.",
  "",
  evidence,
  ...(proof.writeFile.timing ? [
    "", "## Same-engine benchmark", "",
    proof.writeFile.timing.work + " Local Node " + proof.runtime.node + " on " + proof.runtime.cpu + ", seven runs per lane.",
    "",
    "| Backend | Cached (ms) | Uncached (ms) | Uncached / cached |",
    "| --- | ---: | ---: | ---: |",
    ...proof.writeFile.timing.rows.map(row => "| " + row.backend + " | " + row.cachedMs + " | " + row.uncachedMs + " | " + row.speedup + "× |"),
  ] : []),
  "",
].join("\n");
save("proof.md", md);
if (checkDoc) {
  const document = read("docs/DIFFERENTIATION.md").replaceAll("\r\n", "\n");
  const block = document.match(/<!-- BEGIN DIFFERENTIATION EVIDENCE -->([\s\S]*?)<!-- END DIFFERENTIATION EVIDENCE -->/)?.[1];
  assert.equal(block?.trim(), evidence, "Refresh the marked evidence using the generated proof-block.md");
}
console.log("Passed 4 differentiation cases on JS/Wasm GC. Evidence: " + join(output, "proof.md"));
