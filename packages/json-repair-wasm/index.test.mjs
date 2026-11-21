import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createRepairEngine, ExactJsonNumber } from "./index.mjs";

const engine = createRepairEngine();
const schema = JSON.stringify({
  type: "object",
  required: ["user_name", "currency", "amount"],
  properties: {
    user_name: { type: "string" },
    currency: { type: "string", enum: ["USD"] },
    amount: { type: "integer", minimum: 0 },
  },
});
const registry = `{"payment":${schema}}`;

function one(result) {
  assert.equal(result.ok, true, result.wire);
  assert.equal(result.blocks.length, 1);
  return result.blocks[0];
}

test("default file loader uses actual Wasm GC and preserves wide integer text", async () => {
  const api = await engine;
  assert.equal(api.backend, "wasm-gc");
  const result = api.repair('<think>Draft account lookup</think>\n{"id":9007199254740993', { ignoreThink: true });
  const block = one(result);
  assert.equal(block.report.json, '{"id":9007199254740993}');
  assert.equal(block.output, block.report.json);
  assert.deepEqual(block.value, { id: new ExactJsonNumber("9007199254740993") });
  assert.ok(block.report.edits.some(edit => edit.kind === "ignore_think_block"));
  assert.match(result.wire, /"id":9007199254740993/);
});

test("decoded values and the wire retain fraction, exponent and negative-zero lexemes", async () => {
  const source = '{"a":1,"b":1.0,"c":1e+3,"d":-0,"e":0.00000000000000000001,"f":1e1000}';
  const block = one((await engine).repair(source));
  assert.deepEqual(block.value, {
    a: 1,
    b: new ExactJsonNumber("1.0"),
    c: new ExactJsonNumber("1e+3"),
    d: new ExactJsonNumber("-0"),
    e: new ExactJsonNumber("0.00000000000000000001"),
    f: new ExactJsonNumber("1e1000"),
  });
  assert.equal(String(block.value.f), "1e1000");
  assert.equal(block.output, source);
  assert.throws(() => new ExactJsonNumber("01"), TypeError);
});

test("structured errors and English compiler diagnostics use CRLF UTF-16 positions", async () => {
  const result = (await engine).repair('{"name":"王😀",\r\n"amount":1,"amount":2}', { diagnostics: true });
  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "duplicate_key");
  assert.deepEqual(result.error.position, { offset: 27, line: 2, column: 12 });
  assert.match(result.diagnostic, /error\[duplicate_key\]/);
  assert.match(result.diagnostic, /2:12 \(UTF-16\)/);
  assert.match(result.diagnostic, /\n\s*\|\s+\^/);
});

test("JSON5 repairs include Chinese source audit and unchanged machine names", async () => {
  const block = one((await engine).repair("{ amount: 1", { json5: true, diagnostics: true, language: "zh" }));
  assert.equal(block.output, '{"amount":1}');
  assert.match(block.diagnostic, /修复审计/);
  assert.match(block.diagnostic, /\[quote_key\]/);
  assert.match(block.diagnostic, /\^\^\^/);
});

test("semantic coercion is opt-in, audited, and exact at every wire value", async () => {
  const api = await engine;
  const source = '{"userName":"Lin","currency":"usd","amount":"9007199254740993"}';
  const strict = one(api.repair(source, { schema, coerce: true }));
  assert.ok(strict.validation.errors.some(error => error.path === "$.user_name"));
  assert.equal(strict.value.currency, "usd");
  const block = one(api.repair(source, { schema, semantic: true, diagnostics: true }));
  assert.equal(block.value.user_name, "Lin");
  assert.equal(block.value.currency, "USD");
  assert.equal(block.value.amount.source, "9007199254740993");
  assert.deepEqual(block.coercions.map(({ kind, path }) => [kind, path]), [
    ["rename_key", "$.user_name"],
    ["string_to_number", "$.amount"],
    ["normalize_enum", "$.currency"],
  ]);
  assert.equal(block.coercions[1].after.source, "9007199254740993");
  assert.deepEqual(block.validation, { state: "checked", errors: [] });
  assert.equal(block.retry_prompt, "");
  assert.match(block.output, /"amount":9007199254740993/);
});

test("a rejected business constraint gets a path-specific caret and retry prompt", async () => {
  const block = one((await engine).repair('{"userName":"王😀","currency":"usd","amount":-5}', {
    schema, semantic: true, diagnostics: true,
  }));
  assert.equal(block.validation.errors[0].path, "$.amount");
  assert.match(block.retry_prompt, /\$\.amount/);
  assert.match(block.diagnostic, /error\[minimum\]/);
  assert.match(block.diagnostic, /\$\.amount/);
  assert.match(block.diagnostic, /\^\^/);
});

test("extractAll retains block offsets and independent number lexemes", async () => {
  const result = (await engine).extractAll('draft: {"first":1} then {"second":9007199254740993}');
  assert.equal(result.ok, true);
  assert.deepEqual(result.blocks.map(block => [block.start.offset, block.report.json]), [
    [7, '{"first":1}'],
    [24, '{"second":9007199254740993}'],
  ]);
});

test("stream previews do not advance patch history, and simultaneous streams are isolated", async () => {
  const api = await engine;
  const primary = api.createStream();
  const secondary = api.createStream();
  assert.equal(primary.preview().error.kind, "empty_input");
  assert.equal(primary.push('{"id":9007199254740993,"text":"dr').ok, true);
  assert.equal(secondary.push('["separate"]').ok, true);
  assert.equal(one(secondary.nextPatches()).trace.patches_json, '[{"op":"replace","path":"","value":["separate"]}]');
  assert.equal(one(primary.preview()).output, '{"id":9007199254740993,"text":"dr"}');
  const first = one(primary.nextPatches()).trace;
  assert.equal(first.patches[0].value.id.source, "9007199254740993");
  assert.match(first.patches_json, /"id":9007199254740993/);
  assert.ok(first.fields.some(field => field.pointer === "/text" && !field.sealed));
  assert.equal(primary.push('aft"}').ok, true);
  const second = one(primary.nextPatches()).trace;
  assert.deepEqual(second.patches, [{ op: "replace", path: "/text", value: "draft" }]);
  assert.ok(second.fields.some(field => field.pointer === "/text" && field.sealed));
  assert.deepEqual(one(primary.nextPatches()).trace.patches, []);
  const final = primary.finalize();
  assert.equal(final.stream.finalized, true);
  assert.equal(one(final).output, '{"id":9007199254740993,"text":"draft"}');
  assert.strictEqual(primary.finalize(), final);
  assert.strictEqual(primary.preview(), final);
  assert.throws(() => primary.push("x"), /closed/);
  assert.throws(() => primary.nextPatches(), /closed/);
  secondary.close();
  secondary.close();
  assert.throws(() => secondary.preview(), /closed/);
});

test("rejected push leaves the accepted source intact", async () => {
  const stream = (await engine).createStream({ diagnostics: true });
  assert.equal(stream.push('{"keep":').ok, true);
  const attempt = stream.push("x".repeat(1_048_577));
  assert.equal(attempt.ok, false);
  assert.equal(attempt.error.kind, "input_limit");
  assert.equal(attempt.stream.position.offset, 8);
  assert.equal(stream.push("1}").ok, true);
  assert.equal(one(stream.finalize()).output, '{"keep":1}');
});

test("MCP allows exact integer arguments and guards invalid business values", async () => {
  const api = await engine;
  const call = amount => `{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"payment","arguments":{"user_name":"Lin","currency":"USD","amount":${amount}}}}`;
  const allowed = api.guardMcpToolCall(call('"9007199254740993"'), registry, { coerce: true });
  assert.equal(allowed.forward, true);
  assert.equal(allowed.audit.coercions, 1);
  assert.match(allowed.frame, /"id":9007199254740993/);
  assert.match(allowed.frame, /"amount":9007199254740993/);
  const rejected = api.guardMcpToolCall(call("-5"), registry);
  assert.equal(rejected.forward, false);
  assert.equal(rejected.error_code, -32602);
  assert.match(rejected.frame, /"id":9007199254740993/);
  assert.match(JSON.parse(rejected.frame).error.data.retry_prompt, /\$\.amount/);
  const invalid = api.guardMcpToolCall(call("5"), "{");
  assert.ok(invalid.registry_error);
});

test("loader accepts raw bytes, offline fetch URLs, and source-built Wasm modules", async () => {
  const bytes = await readFile(new URL("engine.wasm", import.meta.url));
  const fromBytes = await createRepairEngine({ wasm: bytes });
  const fromUrl = await createRepairEngine({ wasm: new URL(`data:application/wasm;base64,${bytes.toString("base64")}`) });
  const module = await WebAssembly.compile(bytes, { builtins: ["js-string"], importedStringConstants: "_" });
  const fromModule = await createRepairEngine({ wasm: module });
  assert.equal(one(fromBytes.repair("[]")).output, "[]");
  assert.equal(one(fromUrl.repair('["offline"]')).output, '["offline"]');
  assert.equal(one(fromModule.repair("{}")).output, "{}");
  await assert.rejects(createRepairEngine({ wasm: new Uint8Array() }), /Wasm GC and JS string builtins/);
});

test("hosts with a legacy JSON reviver also retain numeric tokens without key collisions", async () => {
  const parse = JSON.parse;
  JSON.parse = (source, reviver) => parse(source, reviver && ((key, value) => reviver(key, value)));
  let compatibility;
  try {
    compatibility = await import("./index.mjs?legacy-json-reviver");
  } finally {
    JSON.parse = parse;
  }
  const api = await compatibility.createRepairEngine();
  const source = '{"\\u0024exactNumber":{"0":1},"$exactNumber$":42,"2":1.0,"1":9007199254740993,"literal":"-0"}';
  const result = one(api.repair(source));
  assert.deepEqual(result.value.$exactNumber, { 0: 1 });
  assert.equal(result.value.$exactNumber$, 42);
  assert.equal(result.value[1].source, "9007199254740993");
  assert.equal(result.value[2].source, "1.0");
  assert.equal(result.value.literal, "-0");
});
