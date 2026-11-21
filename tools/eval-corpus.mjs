import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";
import { corpus, ecosystemPayload } from "../corpus/cases.mjs";
import { moonString, rfcFixtures } from "./rfc-fixtures.mjs";

const repo = fileURLToPath(new URL("../", import.meta.url));
const options = process.argv.slice(2);
const wslIndex = options.indexOf("--native-wsl");
const distribution = wslIndex === -1 ? undefined : options.splice(wslIndex, 2)[1];
if (options.some(option => !["--json", "--native", "--sdk", "--stream-bench"].includes(option)) ||
    (wslIndex !== -1 && (!distribution || process.platform !== "win32")) ||
    (options.includes("--native") && process.platform === "win32" && !distribution)) {
  throw new Error("Usage: node tools/eval-corpus.mjs [--json] [--sdk] [--native (Linux) | --native-wsl DISTRO]");
}

const fixtures = [
  ...corpus.map(fixture => ({ ...fixture, noEdits: false, suite: "llm", precision: fixture.group === "number" })),
  ...rfcFixtures.map(fixture => ({
    ...fixture, output: fixture.output === undefined ? undefined : [fixture.output],
    suite: "rfc8259", group: fixture.class,
  })),
];
assert.ok(corpus.length >= 40 && rfcFixtures.length >= 100);
assert.equal(new Set(fixtures.map(fixture => fixture.id)).size, fixtures.length);

const inputs = fixtures.map(fixture => [
  fixture.source, fixture.schema ? JSON.stringify(fixture.schema) : "",
  ...[fixture.json5, fixture.coerce, fixture.extract, fixture.ignoreThink].map(Boolean),
]);
const bytesPerBatch = fixtures.reduce((sum, { source }) => sum + Buffer.byteLength(source), 0);
const jsBytes = readFileSync(join(repo, "web", "engine.js"));
// This checked-in build uses an IIFE. Keep its export object local while
// measuring its code with the host V8 intrinsics used by the strict parser.
const js = { crypto: globalThis.crypto };
const loadBuild = code => Function("globalThis", code)(js);
loadBuild(jsBytes.toString("utf8"));
assert.equal(typeof js.moonLabRun, "function", "Build the offline engines with node web/build.mjs");
loadBuild(readFileSync(join(repo, "web", "engine-wasm.js"), "utf8"));
const wasmBytes = Buffer.from(js.moonWasmBuild.base64, "base64");
const { instance } = await WebAssembly.instantiate(wasmBytes, {}, { builtins: ["js-string"], importedStringConstants: "_" });
assert.equal(typeof instance.exports.moonLabRun, "function");

const blank = () => ({
  cases: 0, recoverable: 0, accepted: 0, recovered: 0, exact: 0,
  guards: 0, guardsCorrect: 0, schemaCases: 0, schemaExact: 0,
  precisionCases: 0, precisionExact: 0, yCases: 0, yNoEdits: 0, outcomes: 0,
});

function strictRun(source) {
  try {
    return JSON.stringify(JSON.parse(source));
  } catch {
    return undefined;
  }
}

function measure(run, rounds = 25) {
  let checksum = 0;
  for (const args of inputs) checksum += run(...args)?.length ?? 0;
  return medianTime(() => {
    for (let round = 0; round < rounds; round++) {
      for (const args of inputs) checksum += run(...args)?.length ?? 0;
    }
    assert.ok(checksum > 0);
  }, rounds);
}

function medianTime(run, rounds) {
  const ms = medianMilliseconds(run);
  return { repeat: rounds, usPerInput: Number((ms * 1000 / (rounds * inputs.length)).toFixed(2)),
    mbPerSecond: Number((rounds * bytesPerBatch / (ms * 1000)).toFixed(2)) };
}

function medianMilliseconds(run) {
  const durations = [];
  for (let sample = 0; sample < 5; sample++) {
    const start = performance.now();
    run();
    durations.push(performance.now() - start);
  }
  return durations.sort((left, right) => left - right)[2];
}

function artifact(content) {
  return { raw: content.length, gzip: gzipSync(content, { level: 9 }).length };
}

function summarize(name, results, timing, size, failures) {
  const summaries = { llm: blank(), rfc8259: blank() };
  const groups = {};
  results.forEach((raw, index) => {
    const fixture = fixtures[index];
    const group = fixture.suite + "/" + fixture.group;
    if (!groups[group]) groups[group] = blank();
    const count = metric => { summaries[fixture.suite][metric]++; groups[group][metric]++; };
    count("cases");
    if (fixture.output) count("recoverable");
    if (fixture.error) count("guards");
    if (fixture.schema) count("schemaCases");
    if (fixture.precision) count("precisionCases");
    if (fixture.class === "y") count("yCases");
    if (name === "JSON.parse") {
      if (raw === undefined) {
        if (fixture.error) count("guardsCorrect");
        return;
      }
      count("accepted");
      if (fixture.output?.length !== 1) return;
      count("recovered");
      if (raw === fixture.output[0]) {
        count("exact");
        if (fixture.precision) count("precisionExact");
      }
      return;
    }
    try {
      const result = JSON.parse(raw);
      if (result.ok) count("accepted");
      if (fixture.error) {
        assert.equal(result.ok, false);
        assert.equal(result.error.kind, fixture.error);
        count("guardsCorrect");
      } else {
        assert.equal(result.ok, true, result.error?.message);
        assert.equal(result.blocks.length, fixture.output.length, "expected number of calls");
        for (const block of result.blocks) JSON.parse(block.output);
        count("recovered");
        assert.deepEqual(result.blocks.map(block => block.output), fixture.output, "exact text and number lexemes");
        count("exact");
        if (fixture.precision) count("precisionExact");
        if (fixture.noEdits || fixture.suite === "rfc8259") {
          assert.equal(result.blocks[0].report.edits.length === 0, Boolean(fixture.noEdits));
        }
        if (fixture.class === "y") count("yNoEdits");
        if (fixture.ignored !== undefined) {
          const edits = result.blocks.flatMap(block => block.report.edits).filter(edit => edit.kind === "ignore_think_block");
          assert.equal(edits.length, fixture.ignored, "each reasoning range receives one audit");
          for (const edit of edits) {
            assert.match(fixture.source.slice(edit.position.offset, edit.end_offset), /^<think>/i);
            assert.equal(edit.replacement, "");
          }
        }
        if (fixture.schema) {
          const block = result.blocks[0];
          assert.deepEqual(block.validation.errors.map(({ path, keyword }) => [path, keyword]), fixture.errors);
          assert.deepEqual(block.coercions.map(({ path }) => path), fixture.coercions ?? []);
          if (fixture.retry) assert.ok(block.retry_prompt.includes(fixture.retry));
          else assert.equal(block.retry_prompt, "");
          count("schemaExact");
        }
      }
      count("outcomes");
    } catch (error) {
      failures.push({ engine: name, id: fixture.id, failure: error.message });
    }
  });
  return { name, ...summaries, groups, timing, artifact: size };
}

function command(binary, args, cwd) {
  const child = spawnSync(binary, args, {
    cwd, encoding: "utf8", timeout: 120_000, maxBuffer: 24 * 1024 * 1024, env: { ...process.env, WSL_UTF8: "1" },
  });
  if (child.error || child.status !== 0) throw child.error ?? new Error(child.stdout + child.stderr);
  return child.stdout.trim();
}

function nativeEngine() {
  const builds = realpathSync(distribution ? tmpdir() : join(repo, "_build"));
  const temp = mkdtempSync(join(builds, "corpus-native-"));
  try {
    for (const file of readdirSync(repo)) {
      if (["moon.mod", "moon.pkg", "README.md"].includes(file) ||
          (file.endsWith(".mbt") && !/_(test|wbtest)\.mbt$/.test(file))) {
        copyFileSync(join(repo, file), join(temp, file));
      }
    }
    const module = /^name\s*=\s*"([^"]+)"/m.exec(readFileSync(join(temp, "moon.mod"), "utf8"))[1];
    const worker = join(temp, "worker");
    mkdirSync(worker);
    writeFileSync(join(worker, "moon.pkg"), [
      "import {", '  "moonbitlang/core/json",', '  "moonbitlang/core/ref",',
      '  "moonbitlang/core/env",', '  "' + module + '" @repair,', "}",
      'pkgtype(kind: "executable")', "",
    ].join("\n"));
    const bridge = readFileSync(join(repo, "cmd", "playground", "playground.mbt"), "utf8")
      .replace(/^#export_name\([^\n]*\n/gm, "");
    writeFileSync(join(worker, "bridge.mbt"), bridge);
    const rounds = 25;
    const streamOptions = options.includes("--stream-bench") ? nativeStreamProbe() : undefined;
    const entries = inputs.map((args, index) =>
      index + " => lab_run(" + args.map(arg => typeof arg === "string" ? moonString(arg) : String(arg)).join(", ") + ")");
    writeFileSync(join(worker, "worker.mbt"), [
      "///|", "fn evaluate(index : Int) -> String {", "  match index {", ...entries,
      '    _ => ""', "  }", "}", "///|", "fn main {",
      ...(streamOptions ? ['  if @env.args().last() == Some("--stream-bench") {',
        '    stream_bench()', '    return', '  }'] : []),
      '  if @env.args().last() == Some("--benchmark") {',
      "    let mut checksum = 0",
      "    for _ in 0..<" + rounds + " {",
      "      for index in 0..<" + inputs.length + " { checksum += evaluate(index).length() }",
      "    }", "    println(checksum)", "  } else {",
      "    for index in 0..<" + inputs.length + " { println(evaluate(index)) }",
      "  }", "}", "",
    ].join("\n"));
    if (streamOptions) writeFileSync(join(worker, "stream_probe.mbt"), streamOptions.code);
    const args = ["build", "worker", "--target", "native", "--release", "--strip", "--deny-warn", "--output-json"];
    const prefix = distribution ? ["-d", distribution, "--exec"] : [];
    const build = distribution
      ? command("wsl.exe", [...prefix, "bash", "-lc", 'export PATH="$HOME/.moon/bin:$PATH"; exec moon "$@"', "moon", ...args], temp)
      : command("moon", args, temp);
    const info = build.split(/\r?\n/).filter(line => line.startsWith("{")).map(line => JSON.parse(line))
      .find(line => line.$message_type === "artifact" && line.package.endsWith("/worker") && line.target_backend === "native");
    assert.ok(info, "Native compiler did not emit a corpus executable");
    const executable = distribution ? join(temp, "_build", ...info.path.split("/_build/")[1].split("/")) : info.path;
    const run = args => distribution ? command("wsl.exe", [...prefix, info.path, ...args], temp) : command(executable, args, temp);
    const results = run([]).split(/\r?\n/).filter(line => line.startsWith("{"));
    assert.equal(results.length, fixtures.length, "Expected one Native report per fixture");
    const timing = medianTime(() => assert.ok(Number(run(["--benchmark"])) > 0), rounds);
    const streaming = streamOptions ? measureNativeStream(run, streamOptions) : undefined;
    return { results, timing, streaming, size: artifact(readFileSync(executable)) };
  } finally {
    assert.equal(dirname(temp), builds);
    assert.ok(basename(temp).startsWith("corpus-native-"));
    rmSync(temp, { recursive: true, force: true, maxRetries: 4, retryDelay: 100 });
  }
}

function nativeStreamProbe() {
  const source = ecosystemPayload();
  const chunks = source.match(/[\s\S]{1,256}/g);
  // The same bridge exported to Node produces the preview/Patch envelope.
  // Native times whole processes, so report that boundary explicitly.
  const code = [
    "///|", "fn stream_bench() -> Unit {",
    "  let chunks = [", ...chunks.map(chunk => "    " + moonString(chunk) + ","), "  ]",
    "  let mut count = 0", "  let mut prefix = \"\"", "  let mut last = \"\"",
    "  lab_stream_start(false, false)",
    "  for index, chunk in chunks {",
    "    prefix = prefix + chunk",
    "    if !lab_stream_push(chunk) { return }",
    '    last = lab_stream_view(prefix, "", false, false, index == chunks.length() - 1)',
    '    if last.has_prefix("{\\"ok\\":true,") { count += 1 }',
    "  }",
    "  println(count)", "  println(last)", "}", "",
  ].join("\n");
  return { code, source, chunkCount: chunks.length };
}

function measureNativeStream(run, { source, chunkCount }) {
  const replay = () => run(["--stream-bench"]);
  const [count, wire] = replay().split(/\r?\n/);
  assert.equal(Number(count), chunkCount);
  assert.equal(JSON.parse(wire).blocks[0].report.json, source);
  const ms = medianMilliseconds(replay);
  return { snapshots: chunkCount, ms: Number(ms.toFixed(2)), boundary: "spawn + bridge batch + output" };
}

const failures = [];
const engines = [
  summarize("JSON.parse", inputs.map(([source]) => strictRun(source)), measure(strictRun), null, failures),
  summarize("JS", inputs.map(args => js.moonLabRun(...args)), measure(js.moonLabRun), artifact(jsBytes), failures),
  summarize("Wasm GC", inputs.map(args => instance.exports.moonLabRun(...args)), measure(instance.exports.moonLabRun), artifact(wasmBytes), failures),
];
if (distribution || options.includes("--native")) {
  const { results, timing, streaming, size } = nativeEngine();
  engines.push({ ...summarize("Native", results, timing, size, failures), streaming });
}
if (options.includes("--sdk")) {
  const { createRepairEngine } = await import("../packages/json-repair-wasm/index.mjs");
  const sdk = await createRepairEngine();
  const sdkArtifact = readFileSync(join(repo, "packages", "json-repair-wasm", "engine.wasm"));
  const run = (source, schema, json5, coerce, extract, ignoreThink) => {
    const opts = { schema, json5, coerce, ignoreThink };
    return (extract ? sdk.extractAll(source, opts) : sdk.repair(source, opts)).wire;
  };
  engines.push(summarize("Wasm GC SDK", inputs.map(args => run(...args)), measure(run), artifact(sdkArtifact), failures));
}
const report = { fixtureBytesPerBatch: bytesPerBatch, engines, failures };
if (options.includes("--json")) console.log(JSON.stringify(report, null, 2));
else {
  for (const suite of ["llm", "rfc8259"]) {
    console.log(suite);
    console.table(engines.map(engine => ({ engine: engine.name, ...engine[suite] })));
  }
  console.table(engines.map(engine => ({ engine: engine.name, ...engine.timing, gzip: engine.artifact?.gzip })));
  for (const failure of failures) console.error(failure);
}
if (failures.length) process.exitCode = 1;
