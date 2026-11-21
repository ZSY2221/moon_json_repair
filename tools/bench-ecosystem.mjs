import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { cpus } from "node:os";
import { performance } from "node:perf_hooks";
import { fileURLToPath, pathToFileURL } from "node:url";
import { gzipSync } from "node:zlib";
import { corpus, ecosystemPayload } from "../corpus/cases.mjs";
import { rfcFixtures } from "./rfc-fixtures.mjs";
import { createRepairEngine } from "../packages/json-repair-wasm/index.mjs";

const args = process.argv.slice(2);
const usage = "Usage: node tools/bench-ecosystem.mjs [--json] [--native | --native-wsl DISTRO] [--compare-npm MODULE-PATH]";
let compare;
const corpusFlags = [];
const json = args.includes("--json");
for (let index = 0; index < args.length; index++) {
  const option = args[index];
  if (option === "--json") continue;
  if (option === "--native") {
    corpusFlags.push(option);
  } else if (option === "--native-wsl" || option === "--compare-npm") {
    const value = args[++index];
    if (!value || value.startsWith("--")) throw new Error(usage);
    if (option === "--native-wsl") corpusFlags.push(option, value);
    else compare = value;
  } else {
    throw new Error(usage);
  }
}

const repo = fileURLToPath(new URL("../", import.meta.url));
const evaluation = spawnSync(process.execPath, [
  "tools/eval-corpus.mjs", "--json", "--sdk", "--stream-bench", ...corpusFlags,
], { cwd: repo, encoding: "utf8", maxBuffer: 2 * 1024 * 1024, timeout: 300_000 });
if (evaluation.error || evaluation.status !== 0) {
  throw evaluation.error ?? new Error(evaluation.stderr || evaluation.stdout);
}
const { engines } = JSON.parse(evaluation.stdout);
const sdk = await createRepairEngine();
const js = { crypto: globalThis.crypto };
Function("globalThis", readFileSync(new URL("../web/engine.js", import.meta.url), "utf8"))(js);

const source = ecosystemPayload();
assert.equal(Buffer.byteLength(source), 50_000);
const chunks = source.match(/[\s\S]{1,256}/g);
const prefixes = chunks.map((_, index) => source.slice(0, Math.min(source.length, (index + 1) * 256)));

function medianMilliseconds(action) {
  const times = [];
  for (let sample = 0; sample < 5; sample++) {
    const start = performance.now();
    action();
    times.push(performance.now() - start);
  }
  return times.sort((left, right) => left - right)[2];
}

function parseStrict(text) {
  try {
    return JSON.stringify(JSON.parse(text));
  } catch {
    return undefined;
  }
}

function strictStream(retry) {
  let snapshots = 0;
  let last;
  for (const prefix of prefixes) {
    last = retry(prefix);
    if (last !== undefined) snapshots++;
  }
  return { snapshots, last };
}

function sdkStream() {
  const stream = sdk.createStream();
  let snapshots = 0;
  try {
    for (const chunk of chunks) {
      assert.equal(stream.push(chunk).ok, true);
      if (stream.nextPatches().ok) snapshots++;
    }
    return { snapshots, last: stream.finalize().blocks[0].report.json };
  } finally {
    stream.close();
  }
}

function jsStream() {
  js.moonLabStreamStart(false, false);
  let snapshots = 0;
  let frame;
  for (const [index, chunk] of chunks.entries()) {
    assert.equal(js.moonLabStreamPush(chunk), true);
    const last = index === chunks.length - 1;
    frame = JSON.parse(js.moonLabStreamView(prefixes[index], "", false, false, last));
    if (frame.ok) snapshots++;
  }
  return { snapshots, last: frame.blocks[0].report.json };
}

function timeStream(run, boundary, { snapshots, last }) {
  const observed = run();
  assert.equal(observed.snapshots, snapshots);
  assert.equal(observed.last, last);
  return { snapshots, ms: Number(medianMilliseconds(run).toFixed(2)), boundary };
}

const exact = { snapshots: chunks.length, last: source };
const strict = { snapshots: 1, last: source.replace("9007199254740993", "9007199254740992") };
const streaming = {
  "JSON.parse": timeStream(() => strictStream(parseStrict), "full prefix parse + stringify when valid", strict),
  "JS": timeStream(jsStream, "stream push + serialized Patch report", exact),
  "Wasm GC SDK": timeStream(sdkStream, "SDK stream push + decoded Patch report", exact),
};

function summary(engine) {
  const suites = [engine.rfc8259, engine.llm];
  const sum = flag => suites.reduce((count, suite) => count + suite[flag], 0);
  return {
    engine: engine.name,
    validOutputs: sum("recovered"),
    exactExpected: sum("exact"),
    recoverableFixtures: sum("recoverable"),
    exactWideNumbers: sum("precisionExact"),
    wideNumberFixtures: sum("precisionCases"),
    usPerFixture: engine.timing.usPerInput,
    gzipBytes: engine.artifact?.gzip ?? null,
    stream: engine.streaming ?? streaming[engine.name] ?? null,
  };
}

const results = engines.filter(engine => engine.name !== "Wasm GC").map(summary);
const fixtures = [...corpus, ...rfcFixtures].map(fixture => ({
  ...fixture,
  output: typeof fixture.output === "string" ? [fixture.output] : fixture.output,
}));
const externalPrecision = fixture => fixture.precision || fixture.group === "number";

if (compare) {
  const require = createRequire(import.meta.url);
  const callerRequire = createRequire(pathToFileURL(process.cwd() + "/benchmark.cjs"));
  let entry;
  try {
    entry = callerRequire.resolve(compare);
  } catch (error) {
    if (error.code !== "MODULE_NOT_FOUND") throw error;
    entry = require.resolve(compare);
  }
  const library = await import(pathToFileURL(entry));
  const repair = library.jsonrepair ?? library.repair ?? library.default?.jsonrepair ?? library.default;
  if (typeof repair !== "function") throw new TypeError("Comparator must export jsonrepair, repair, or a default function.");
  const compact = text => text.replace(/"(?:[^"\\]|\\[\s\S])*"|\s+/g, token => token.startsWith('"') ? token : "");
  const attempt = text => {
    try {
      const output = repair(text);
      if (typeof output !== "string") return undefined;
      JSON.parse(output);
      return compact(output);
    } catch {
      return undefined;
    }
  };
  const outcomes = fixtures.map(fixture => ({
    ...fixture, actual: attempt(fixture.source),
  }));
  const matched = fixture => fixture.output?.length === 1 && fixture.actual === compact(fixture.output[0]);
  const successful = outcomes.filter(fixture => fixture.output && fixture.actual !== undefined);
  const repeats = 25;
  const ms = medianMilliseconds(() => {
    for (let repeat = 0; repeat < repeats; repeat++) {
      for (const fixture of fixtures) attempt(fixture.source);
    }
  });
  const externalStream = () => strictStream(attempt);
  const { snapshots, last } = externalStream();
  results.push({
    engine: "Local npm: " + compare,
    validOutputs: successful.length,
    exactExpected: outcomes.filter(matched).length,
    recoverableFixtures: outcomes.filter(fixture => fixture.output).length,
    exactWideNumbers: outcomes.filter(fixture => externalPrecision(fixture) && matched(fixture)).length,
    wideNumberFixtures: outcomes.filter(externalPrecision).length,
    usPerFixture: Number((ms * 1000 / (repeats * fixtures.length)).toFixed(2)),
    gzipBytes: gzipSync(readFileSync(entry), { level: 9 }).length,
    stream: {
      ...timeStream(externalStream, "full prefix repair + strict validation", { snapshots, last }),
      exactFinal: last === source,
    },
  });
}

const report = {
  node: process.version,
  cpu: cpus()[0]?.model.trim(),
  host: process.platform,
  rfc: rfcFixtures.length,
  modeledFaults: corpus.length,
  streamBytes: Buffer.byteLength(source),
  streamChunkUnits: 256,
  streamChunks: chunks.length,
  results,
};
if (json) {
  console.log(JSON.stringify(report, null, 2));
} else {
  console.log(process.version + " · " + report.cpu + " · " + report.host);
  console.log(report.rfc + " RFC + " + report.modeledFaults + " modeled faults · " + report.streamBytes + " B / " + report.streamChunks + " stream chunks");
  console.table(results.map(({ stream, ...row }) => ({
    ...row, streamSnapshots: stream?.snapshots, streamMs: stream?.ms, streamScope: stream?.boundary,
  })));
  console.log("Sizes are the measured engine artifacts, or the resolved entry file for an optional npm comparator.");
  console.log("Native timings include process overhead. The strict parser cannot emit patches from invalid prefixes.");
}
