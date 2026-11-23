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
const { instance, module } = await WebAssembly.instantiate(bytes, {}, {
  builtins: ["js-string"], importedStringConstants: "_",
});
const engines = [["JS", jsEngine], ["Wasm GC", instance.exports]];
assert.deepEqual(WebAssembly.Module.imports(module), []);
const publicExports = [
  "moonRepairPayload", "moonLabRun", "moonLabStreamStart", "moonLabStreamPush",
  "moonLabStreamView", "moonLabRepairOnly", "moonLabGuardMcp", "moonLabBenchStart",
  "moonLabBenchStep", "moonLabBenchMatches", "moonLabBenchFinish",
  "moonLabRunWithOptions", "moonLabStreamViewWithOptions",
];
for (const [name, engine] of engines) {
  for (const entry of publicExports) assert.equal(typeof engine[entry], "function", name + " " + entry);
}

const html = readWeb("index.html");
assert.doesNotMatch(
  html.replace(/<button\b[^>]*\bid="lang-zh"[^>]*>[^<]*<\/button>/, ""),
  /\p{Script=Han}/u,
  "Built-in English document text should not mix languages outside the picker",
);
const scripts = [...html.matchAll(/<script\b[^>]*\bsrc="([^"]+)"/g)].map(match => match[1]);
assert.ok(scripts.includes("./i18n.js"), "The page must load its offline language catalog");
for (const script of scripts) {
  assert.match(script, /^\.\/[a-z0-9-]+\.js$/, "Playground scripts must use local relative paths");
  assert.ok(readWeb(script).length > 0);
}
for (const script of ["./json-view.js", "./lab-tools.js", "./arena.js", "./app.js"]) {
  assert.ok(scripts.indexOf("./i18n.js") < scripts.indexOf(script), "Localization must load before " + script);
}
for (const [stylesheet] of html.matchAll(/<link\b[^>]*\brel="stylesheet"[^>]*>/g)) {
  const link = stylesheet.match(/\bhref="([^"]+)"/)?.[1];
  assert.match(link, /^\.\/[a-z0-9-]+\.css$/, "Playground stylesheets must use local relative paths");
  assert.ok(readWeb(link).length > 0);
}

const fixtures = runInNewContext(
  ["i18n.js", "examples.js", "json-view.js", "lab-tools.js", "arena.js"].map(readWeb).join("\n") +
  "\n;({ writeFileInput, mcpRegistry, examples, labFixtures, moonbitSnippet, cliSnippet, resolveLabLanguage, inspectLabInput, labChinese, labMcpFrame, duelFixtures, duelChunks, duelJsonPrefix, applyDuelOperations, jsonView, makeChaosCases, classifyChaosReport, setLanguage: value => { labLanguage = value; } })",
  { URLSearchParams },
);
const entities = { "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&#39;": "'" };
const decode = text => text.trim().replace(/&(amp|lt|gt|quot|#39);/g, entity => entities[entity]);
const staticMessages = [...html.matchAll(/<([a-z][\w-]*)\b[^>]*\bdata-i18n(?=\s|>)[^>]*>([^<]*)<\/\1>/g)]
  .map(match => decode(match[2]));
for (const [marker, attribute] of [["aria", "aria-label"], ["placeholder", "placeholder"], ["description", "content"]]) {
  for (const item of html.matchAll(new RegExp('<[^>]*\\bdata-i18n-' + marker + '\\b[^>]*>', "g"))) {
    const value = item[0].match(new RegExp('\\b' + attribute + '="([^"]+)"'));
    assert.ok(value, "Missing localized " + attribute);
    staticMessages.push(decode(value[1]));
  }
}
assert.ok(staticMessages.length > 55, "All static interface messages should be marked for translation");
const requiredMessages = new Set(staticMessages);
for (const example of [...fixtures.examples, ...fixtures.labFixtures]) {
  assert.ok(example.description, "Every preset needs a localized description");
  requiredMessages.add(example.label);
  requiredMessages.add(example.description);
}
for (const file of ["app.js", "json-view.js", "lab-tools.js", "arena.js"]) {
  const calls = readWeb(file).matchAll(/\blab(?:Text\(\s*|Set\([^,\r\n]+,\s*)("(?:[^"\\]|\\.)*")/g);
  for (const [, literal] of calls) {
    const message = JSON.parse(literal);
    if (message) requiredMessages.add(message);
  }
}
for (const message of requiredMessages) assert.ok(Object.hasOwn(fixtures.labChinese, message), "Missing Chinese translation for " + message);
const placeholders = message => (message.match(/\{\d+\}/g) ?? []).sort();
for (const [english, chinese] of Object.entries(fixtures.labChinese)) {
  assert.doesNotMatch(english, /\p{Script=Han}/u, "English catalog has Chinese text");
  assert.match(chinese, /\p{Script=Han}/u, "Chinese catalog has no Chinese text: " + english);
  assert.deepEqual(placeholders(chinese), placeholders(english), "Template parameters differ: " + english);
}

for (const [query, saved, locale, expected] of [
  ["?lang=zh", "en", "en-GB", "zh"],
  ["?lang=en", "zh", "zh-CN", "en"],
  ["?lang=unsupported", "zh", "en-GB", "zh"],
  ["", "en", "zh-CN", "en"],
  ["", "", "zh-Hant-TW", "zh"],
  ["", "", "en-US", "en"],
]) {
  assert.equal(fixtures.resolveLabLanguage(query, saved, locale), expected);
}

const extremeInputs = [
  ["input_limit", "?".repeat(500_000), ""],
  ["input_limit", "é".repeat(250_000), ""],
  ["input_limit", "?".repeat(500 * 1024), ""],
  ["depth_limit", "[".repeat(1_000) + "0" + "]".repeat(1_000), ""],
  ["escape_limit", '{"value":"' + "\\q".repeat(17_000) + '"}', ""],
  ["line_limit", "\n".repeat(8_001), ""],
  ["schema_limit", "{}", " ".repeat(32_001)],
];
for (const [expected, source, schema] of extremeInputs) {
  const rejected = fixtures.inspectLabInput(source, schema);
  assert.equal(rejected?.kind, expected);
  assert.ok(Number.isInteger(rejected.limit) && rejected.limit > 0, expected + " needs a numeric budget");
}
for (const [expected, limit, probe] of [
  ["input_limit", 128_000, n => fixtures.inspectLabInput(" ".repeat(n), "")],
  ["schema_limit", 32_000, n => fixtures.inspectLabInput("{}", " ".repeat(n))],
  ["line_limit", 8_000, n => fixtures.inspectLabInput("\n".repeat(n - 1), "")],
  ["depth_limit", 256, n => fixtures.inspectLabInput("[".repeat(n) + "0" + "]".repeat(n), "")],
  ["escape_limit", 16_000, n => fixtures.inspectLabInput('{"value":"' + "\\q".repeat(n) + '"}', "")],
]) {
  assert.equal(probe(limit), null, expected + " should accept the displayed maximum");
  const rejection = probe(limit + 1);
  assert.equal(rejection?.kind, expected);
  assert.equal(rejection.limit, limit);
}
for (const source of [
  "", "🌙🧪🚀", '{"value":"' + "[".repeat(1_000) + '"}',
  "/* " + "[".repeat(1_000) + " */ {}", fixtures.writeFileInput,
]) {
  assert.equal(fixtures.inspectLabInput(source, ""), null, "A safe source must reach the repair engine");
}
const smallInputs = [
  ["", false, "empty_input"],
  ["🌙🧪🚀", false, "unexpected_token"],
  ['{"value":"🌙🧪🚀","id":9007199254740993}', true, ""],
];
for (const [source, expected, error] of smallInputs) {
  const raw = engines.map(([, engine]) => engine.moonLabRun(source, "", false, false, false, false));
  assert.equal(raw[0], raw[1], "Engine parity for empty, emoji, and exact decimal input");
  const result = JSON.parse(raw[0]);
  assert.equal(result.ok, expected);
  if (error) assert.equal(result.error.kind, error);
  else assert.match(result.blocks[0].report.json, /"id":9007199254740993/);
}
console.log(requiredMessages.size + " translated interface/preset messages, language precedence, offline assets, and five input budgets verified.");

function exactResult(method, args, description) {
  const results = engines.map(([, engine]) => engine[method](...args));
  assert.equal(results[0], results[1], description + " differs between JS and Wasm GC");
  return JSON.parse(results[0]);
}

const semanticInput = '{\r\n  "userName": "Ada",\r\n  "currency": " usd ",\r\n  "amount": "9007199254740993"\r\n}';
const semanticSchema = JSON.stringify({
  type: "object",
  required: ["user_name", "currency", "amount"],
  properties: {
    user_name: { type: "string" },
    currency: { type: "string", enum: ["USD", "EUR"] },
    amount: { type: "integer" },
  },
});
const runOptions = (source, schema, { coerce = false, semantic = false, diagnostics = true, chinese = false } = {}) =>
  exactResult("moonLabRunWithOptions", [source, schema, false, coerce, false, false, semantic, diagnostics, chinese],
    "Extended repair report");
const ordinaryCoercion = runOptions(semanticInput, semanticSchema, { coerce: true });
assert.ok(ordinaryCoercion.blocks[0].validation.errors.length >= 2);
assert.match(ordinaryCoercion.blocks[0].output, /"userName":"Ada"/);
for (const chinese of [false, true]) {
  const result = runOptions(semanticInput, semanticSchema, { coerce: true, semantic: true, chinese });
  assert.equal(result.ok, true);
  const block = result.blocks[0];
  assert.equal(block.validation.errors.length, 0);
  assert.match(block.output, /"user_name":"Ada"/);
  assert.match(block.output, /"currency":"USD"/);
  assert.match(block.output, /"amount":9007199254740993/);
  assert.deepEqual(new Set(block.coercions.map(edit => edit.kind)), new Set(["rename_key", "normalize_enum", "string_to_number"]));
}
const noCoercion = runOptions(semanticInput, semanticSchema, { semantic: true });
assert.ok(noCoercion.blocks[0].validation.errors.length >= 2, "Semantic repairs must be opt-in with schema coercion");
assert.equal(noCoercion.blocks[0].coercions.length, 0);

const semanticPreset = fixtures.labFixtures.find(({ label }) => label === "Semantic normalization");
const presetSchema = JSON.stringify(semanticPreset.schema);
const presetRepaired = runOptions(semanticPreset.input, presetSchema, semanticPreset.modes);
assert.equal(presetRepaired.ok, true);
const presetBlock = presetRepaired.blocks[0];
assert.equal(presetBlock.output, '{"tool":"record_payment","args":{"currency":"USD","amount":9007199254740993,"user_name":"Ada"}}');
assert.deepEqual(presetBlock.validation, { state: "checked", errors: [] });
assert.deepEqual(presetBlock.coercions.map(({ path, kind }) => [path, kind]).sort(), [
  ["$.args.amount", "string_to_number"],
  ["$.args.currency", "normalize_enum"],
  ["$.args.user_name", "rename_key"],
]);
assert.match(presetBlock.diagnostic, /\^/u);
const presetStrict = runOptions(semanticPreset.input, presetSchema, { coerce: true, semantic: false });
assert.ok(presetStrict.blocks[0].validation.errors.some(({ path }) => path === "$.args.user_name"));

const duplicate = '{\r\n  "item": "星球🌙",\r\n  "item": "again"\r\n}';
const badSchemaInput = '{\r\n  "user_name": "星球🌙",\r\n  "currency": "USD",\r\n  "amount": "wrong"\r\n}';
for (const chinese of [false, true]) {
  const error = runOptions(duplicate, "", { chinese });
  assert.equal(error.ok, false);
  assert.equal(error.error.kind, "duplicate_key");
  assert.match(error.diagnostic, chinese ? /错误\[duplicate_key\]/u : /error\[duplicate_key\]/u);
  assert.match(error.diagnostic, /3\s*\|\s+"item": "again"/u);
  assert.match(error.diagnostic, /\^/u);

  const validation = runOptions(badSchemaInput, semanticSchema, { chinese });
  assert.ok(validation.blocks[0].validation.errors.length > 0);
  const diagnostic = validation.blocks[0].diagnostic;
  assert.match(diagnostic, chinese ? /错误\[type\]/u : /error\[type\]/u);
  assert.match(diagnostic, /\$\.amount/u);
  assert.match(diagnostic, /1\s*\|[^\n]*"amount":"wrong"/u);
  assert.match(diagnostic, /\^{5,}/u);

  const audited = runOptions('{name: "Ada",}', "", { chinese });
  assert.equal(audited.ok, true);
  assert.match(audited.blocks[0].output, /"name":"Ada"/u);
  assert.match(audited.blocks[0].diagnostic, /1\s*\|\s*\{name: "Ada",\}/u);
  assert.match(audited.blocks[0].diagnostic, /\^/u);
}
assert.equal(runOptions(duplicate, "", { diagnostics: false }).diagnostic, undefined);

for (const [, engine] of engines) engine.moonLabStreamStart(false, false);
let extendedFrames = 0;
for (let offset = 0; offset < semanticInput.length; offset += 3) {
  const end = Math.min(offset + 3, semanticInput.length);
  for (const [, engine] of engines) assert.ok(engine.moonLabStreamPush(semanticInput.slice(offset, end)));
  const view = exactResult("moonLabStreamViewWithOptions",
    [semanticInput.slice(0, end), semanticSchema, true, false, end === semanticInput.length, true, true, false],
    "Extended stream checkpoint " + end);
  if (end === semanticInput.length) {
    assert.match(view.blocks[0].output, /"amount":9007199254740993/);
    assert.equal(view.blocks[0].validation.errors.length, 0);
  }
  extendedFrames++;
}
console.log("Compiler-style carets, locale, exact semantic coercion, and " + extendedFrames + " extended stream checkpoints verified.");

function applyFixturePatch(value, patch) {
  if (patch.path === "") return patch.op === "remove" ? null : structuredClone(patch.value);
  assert.ok(patch.path.startsWith("/"), "Expected JSON Pointer");
  const path = patch.path.slice(1).split("/").map(part => part.replaceAll("~1", "/").replaceAll("~0", "~"));
  const parent = path.slice(0, -1).reduce((node, key) => node[key], value);
  const key = path.at(-1);
  if (Array.isArray(parent)) {
    const index = key === "-" ? parent.length : Number(key);
    if (patch.op === "add") parent.splice(index, 0, structuredClone(patch.value));
    else if (patch.op === "remove") parent.splice(index, 1);
    else parent[index] = structuredClone(patch.value);
  } else if (patch.op === "remove") {
    delete parent[key];
  } else {
    parent[key] = structuredClone(patch.value);
  }
  return value;
}

for (const [name, fixture] of Object.entries(fixtures.duelFixtures)) {
  const { fields } = fixture;
  const chunks = fixtures.duelChunks(fixture);
  const draftChunks = chunks.length - fixture.chunks.length;
  assert.ok(draftChunks > 1 && fixture.chunks.length > 1);
  for (const [, engine] of engines) engine.moonLabStreamStart(false, true);
  const projection = new Map();
  let source = "";
  let value = null;
  let earlySeal = false;
  let patchCount = 0;
  let strictReadyAt = -1;
  let firstFieldAt = -1;
  let ignoredDraft = false;
  for (const [index, chunk] of chunks.entries()) {
    source += chunk;
    try {
      JSON.parse(fixtures.duelJsonPrefix(source));
      if (strictReadyAt < 0) strictReadyAt = index;
    } catch (error) {
      assert.ok(error instanceof SyntaxError);
    }
    for (const [, engine] of engines) assert.ok(engine.moonLabStreamPush(chunk));
    const result = exactResult("moonLabStreamView", [source, "", false, false, index === chunks.length - 1], "Duel " + name + " checkpoint " + index);
    const block = result.blocks?.[0];
    if (index < draftChunks) assert.equal(block, undefined, "Draft must never create a visible tool call");
    const trace = block?.trace;
    if (!trace) continue;
    ignoredDraft ||= block.report.edits.some(edit => edit.kind === "ignore_think_block");
    assert.doesNotMatch(trace.json, /Draft only|scratch|<think>/u);
    for (const patch of trace.patches) {
      assert.ok(["add", "remove", "replace"].includes(patch.op));
      value = applyFixturePatch(value, patch);
      patchCount++;
    }
    assert.deepEqual(value, JSON.parse(trace.json), "Duel patches must reproduce the reported checkpoint");
    fixtures.applyDuelOperations(projection, trace, fixture);
    if (firstFieldAt < 0 && [...projection.values()].some(text => text !== "")) firstFieldAt = index;
    const snapshot = fixtures.jsonView(trace.json);
    for (const { key } of fields) {
      const span = snapshot.pointers.get("/args/" + key);
      const raw = span ? trace.json.slice(span.start, span.end) : undefined;
      const expected = raw?.startsWith('"') ? JSON.parse(raw) : raw;
      assert.equal(projection.get(key), expected, "Duel projection differs from the checkpoint at /args/" + key);
    }
    if (strictReadyAt < 0 && trace.fields.some(({ pointer, sealed }) => pointer.startsWith("/args/") && sealed)) {
      earlySeal = true;
    }
  }
  assert.match(source, /^<think>\n\{"tool":"scratch".*\n<\/think>\n/u);
  assert.equal(fixtures.duelJsonPrefix(source), fixture.chunks.join(""));
  assert.ok(ignoredDraft, name + " must audit reasoning isolation");
  assert.equal(firstFieldAt, draftChunks + 1, name + " must render from the second payload chunk");
  assert.equal(strictReadyAt, chunks.length - 1, name + " strict parser must wait for the final chunk");
  assert.ok(earlySeal && patchCount > 0, name + " must provide real sealed fields and patches before strict parsing succeeds");
  if (name === "checkout") assert.equal(projection.get("order_id"), "9007199254740993");
  console.log("Duel " + name + " · " + chunks.length + " exact checkpoints including " + draftChunks +
    " draft chunks · first field at JSON chunk 2 · " + patchCount + " replayed Patch operations");
}

const arenaSeed = 0x05eeda11;
const chaos = fixtures.makeChaosCases();
assert.equal(chaos.length, 1_152, "Node smoke must use the full Chaos Arena default sample set");
assert.deepEqual(fixtures.makeChaosCases(arenaSeed, 1_152), chaos, "Chaos default seed and explicit seed differ");
assert.notDeepEqual(fixtures.makeChaosCases(arenaSeed + 1, 1_152), chaos, "Alternate seed should vary the Chaos cases");
assert.ok(new Set(chaos.map(({ kind }) => kind)).size >= 5, "Chaos needs varied perturbation families");
const chaosCounts = { repaired: 0, refused: 0, panic: 0 };
for (const [index, { source, kind, json5, ignoreThink }] of chaos.entries()) {
  const [jsWire, wasmWire] = engines.map(([, engine]) => engine.moonLabRun(source, "", json5, false, false, ignoreThink));
  assert.equal(jsWire, wasmWire, "Chaos seed checkpoint " + index + " (" + kind + ")");
  const category = fixtures.classifyChaosReport(wasmWire);
  assert.ok(Object.hasOwn(chaosCounts, category), "Unknown Chaos outcome");
  chaosCounts[category]++;
  const envelope = JSON.parse(wasmWire);
  if (category === "repaired") {
    assert.equal(envelope.ok, true);
    assert.ok(envelope.blocks.length > 0);
    for (const block of envelope.blocks) assert.doesNotThrow(() => JSON.parse(block.output));
  } else if (category === "refused") {
    assert.equal(envelope.ok, false);
    assert.equal(typeof envelope.error.kind, "string");
  }
}
assert.equal(chaosCounts.panic, 0, "Chaos must not produce bridge failures");
assert.ok(chaosCounts.repaired > 0 && chaosCounts.refused > 0);
assert.equal(chaosCounts.repaired + chaosCounts.refused, chaos.length);
console.log("Chaos Arena · " + chaos.length + " exact dual-engine cases · " + chaosCounts.repaired +
  " valid repairs · " + chaosCounts.refused + " safe refusals · " + chaosCounts.panic + " bridge failures");

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
const rejectedFrame = rejectedFrames[0].frame;
assert.equal(fixtures.labMcpFrame(rejectedFrame), rejectedFrame);
fixtures.setLanguage("zh");
const localFrame = fixtures.labMcpFrame(rejectedFrame);
assert.match(localFrame, /"id":9007199254740993(?=[,}])/u);
assert.match(rejectedFrame, /Invalid params/u);
assert.doesNotMatch(localFrame, /Invalid params|expected string|Unicode code points/u);
const localError = JSON.parse(localFrame).error;
assert.equal(localError.code, -32602);
assert.equal(localError.message, "参数无效");
assert.ok(localError.data.issues.every(({ message }) => /\p{Script=Han}/u.test(message)));
assert.match(localError.data.retry_prompt, /"expected":"应为字符串"/u);
fixtures.setLanguage("en");
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
fixtures.setLanguage("zh");
const chineseCode = fixtures.moonbitSnippet(allowed, registry, flags);
const chineseCli = fixtures.cliSnippet(allowed, registry, flags);
const commentLines = (text, starts) => text.split("\n").filter(line => line.startsWith(starts));
assert.ok(commentLines(chineseCode, "//").some(line => /\p{Script=Han}/u.test(line)));
const chineseComments = commentLines(chineseCli, "#");
assert.ok(chineseComments.length >= 2 && chineseComments.every(line => /\p{Script=Han}/u.test(line)));
assert.deepEqual(
  chineseCode.split("\n").filter(line => !line.startsWith("//")),
  code.split("\n").filter(line => !line.startsWith("//")),
  "Localized MoonBit snippets must generate the same executable code",
);
assert.deepEqual(
  chineseCli.split("\n").filter(line => !line.startsWith("#")),
  escaped.split("\n").filter(line => !line.startsWith("#")),
  "Localized CLI snippets must generate the same executable commands",
);
console.log("MCP exact wire form and audit agreed across both engines. Localized error preview preserves the exact ID. Generated snippets reflect the active options.");
