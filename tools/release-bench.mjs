import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { cpus, homedir, platform, tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";
import { gzipSync } from "node:zlib";

const repository = fileURLToPath(new URL("../", import.meta.url));
const [flag, distribution, ...extra] = process.argv.slice(2);
if (extra.length || (flag && (flag !== "--native-wsl" || !distribution || platform() !== "win32"))) {
  throw new Error("Usage: node tools/release-bench.mjs [--native-wsl DISTRO]");
}
const targets = ["js", "wasm-gc"];
if (platform() !== "win32" || distribution) targets.push("native");
const tempRoot = realpathSync(tmpdir());
const prefix = "moon-json-repair-bench-";
const workspace = mkdtempSync(join(tempRoot, prefix));

const strict = [
  "fn strict_json(source : String) -> String {",
  "  try {",
  "    @json.parse(source[:], preserve_number_repr=true, reject_duplicate_keys=true).stringify()",
  "  } catch {",
  '    _ => ""',
  "  }",
  "}",
].join("\n");
const repair = [
  "fn repaired_json(source : String) -> String {",
  "  match @repair.repair(source) {",
  "    Ok(report) => report.json",
  '    Err(_) => ""',
  "  }",
  "}",
].join("\n");

function executableSource(helper, conversion) {
  return [
    "///|",
    helper,
    "",
    "///|",
    "fn main {",
    '  let source = #|{"tool":"echo","args":{"text":"moon","limit":3}}',
    "  println(" + conversion + "(source))",
    "}",
  ].join("\n");
}

function makePackage(module, name, source, foreign = false, needsRepair = false) {
  const directory = join(workspace, name);
  mkdirSync(directory);
  const imports = [
    ...(source.includes("@json.") ? ['  "moonbitlang/core/json",'] : []),
    ...(needsRepair ? ['  "' + module + '" @repair,'] : []),
  ];
  const kind = foreign ? 'pkgtype(kind: "foreign_library")\noptions(link: { "js": { "format": "cjs" } })'
    : 'pkgtype(kind: "executable")';
  writeFileSync(join(directory, "moon.pkg"), "import {\n" + imports.join("\n") + "\n}\n\n" + kind + "\n");
  writeFileSync(join(directory, "probe.mbt"), source + "\n");
}

function runMoon(args, wsl = false, cwd = workspace) {
  const options = { cwd, encoding: "utf8", env: { ...process.env, WSL_UTF8: "1" } };
  let run = wsl
    ? spawnSync("wsl.exe", ["-d", distribution, "-e", "bash", "-lc",
      'export PATH="$HOME/.moon/bin:$PATH"; exec moon "$@"', "moon", ...args], options)
    : spawnSync("moon", args, options);
  if (!wsl && run.error?.code === "ENOENT") {
    const moon = platform() === "win32" ? "moon.exe" : "moon";
    run = spawnSync(join(homedir(), ".moon", "bin", moon), args, options);
  }
  if (run.error || run.status !== 0) {
    throw run.error ?? new Error("moon " + args.join(" ") + "\n" + run.stdout + run.stderr);
  }
  return run.stdout;
}

function compile(name, target) {
  const wsl = target === "native" && Boolean(distribution);
  const output = runMoon(["build", name, "--target", target, "--release", "--strip", "--deny-warn", "--output-json"], wsl);
  const metadata = output.split(/\r?\n/).filter(line => line.startsWith("{")).map(line => JSON.parse(line))
    .find(message => message.$message_type === "artifact" && message.target_backend === target
      && message.package.endsWith("/" + name));
  assert.ok(metadata, "Compiler did not report " + name + " " + target + " output");
  if (!wsl) return metadata.path;
  const suffix = metadata.path.match(/\/_build\/(.+)$/)?.[1];
  assert.ok(suffix, "Unexpected WSL build artifact path " + metadata.path);
  return join(workspace, "_build", ...suffix.split("/"));
}

function median(values) {
  const sorted = values.toSorted((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function timeBatch(convert, input, count) {
  let length = 0;
  const start = performance.now();
  for (let iteration = 0; iteration < count; iteration++) {
    length += convert(input).length;
  }
  const duration = (performance.now() - start) * 1000 / count;
  assert.ok(Number.isInteger(length));
  return duration;
}

function measureFixtures({ moonStrictRelease: strictJson, moonRepairRelease: repairedJson }) {
  const catalog = readFileSync(join(repository, "web", "examples.js"), "utf8");
  const allExamples = runInNewContext(catalog + "\nexamples");
  const fixtureLabels = ["Stream cut", "Markdown & prose", "Python & JS literals", "Comments", "Keys & commas", "Schema rejection"];
  const examples = fixtureLabels.map(label => {
    const fixture = allExamples.find(example => example.label === label);
    assert.ok(fixture, "Missing strict comparison fixture " + label);
    return fixture;
  });
  const expected = [
    { tool: "create_ticket", args: { priority: "high", retries: 2, title: "Investigate checkout timeout" } },
    { tool: "search_docs", args: { query: "MoonBit JSON repair", limit: 3 } },
    { tool: "set_preferences", args: { daily_email: true, sms: false, timezone: null, backup: null } },
    { tool: "fetch_url", args: { url: "https://example.com/help", retries: 2 } },
    { tool: "send_notice", args: { channel: "ops", body: "Checkout is back online\nThanks for your patience" } },
    { tool: "record_payment", args: { amount: -12.5, currency: "BTC", tags: ["invoice", 42] } },
  ];
  assert.equal(examples.length, expected.length);
  assert.equal(typeof strictJson, "function");
  assert.equal(typeof repairedJson, "function");
  const rows = [];
  for (const [index, { input, label }] of examples.entries()) {
    const strictOutput = strictJson(input);
    const repairedOutput = repairedJson(input);
    assert.equal(strictOutput, "", label + " should be rejected by the strict parser");
    assert.deepEqual(JSON.parse(repairedOutput), expected[index], label + " repaired incorrectly");
    assert.deepEqual(JSON.parse(strictJson(repairedOutput)), expected[index], label + " is not strict JSON");
    timeBatch(strictJson, input, 10_000);
    timeBatch(repairedJson, input, 10_000);
    const strictTimes = [];
    const repairTimes = [];
    for (let sample = 0; sample < 9; sample++) {
      if (sample % 2 === 0) {
        strictTimes.push(timeBatch(strictJson, input, 10_000));
        repairTimes.push(timeBatch(repairedJson, input, 10_000));
      } else {
        repairTimes.push(timeBatch(repairedJson, input, 10_000));
        strictTimes.push(timeBatch(strictJson, input, 10_000));
      }
    }
    rows.push({
      label,
      strict: "rejected",
      repaired: "expected JSON",
      strictUs: Number(median(strictTimes).toFixed(2)),
      repairUs: Number(median(repairTimes).toFixed(2)),
    });
  }
  return rows;
}

function fileSizes(path) {
  const content = readFileSync(path);
  return { raw: content.byteLength, gzip: gzipSync(content, { level: 9 }).byteLength };
}

function measureScaling(moduleName, target) {
  const output = runMoon([
    "bench", "--target", target, "--release", "--no-parallelize", "--deny-warn",
    "--package", moduleName, "--file", "scaling_bench_test.mbt",
  ], target === "native" && Boolean(distribution), repository);
  const factors = { ns: 0.001, "µs": 1, "μs": 1, us: 1, ms: 1000, s: 1_000_000 };
  const means = new Map();
  for (const line of output.split(/\r?\n/)) {
    const row = line.match(/^(scale-\d+|stream-(?:preview|final)-\d+)\s+([\d.]+)\s+(ns|[µμu]s|ms|s)\s+±/);
    if (row) means.set(row[1], Number(row[2]) * factors[row[3]]);
  }
  assert.equal(means.size, 10, "Unexpected MoonBit benchmark output:\n" + output);
  for (const bytes of [200, 2_000, 20_000, 100_000]) {
    const meanUs = means.get("scale-" + bytes);
    console.log(JSON.stringify({ target, bytes, meanUs, mbPerSecond: Number((bytes / meanUs).toFixed(2)) }));
  }
  for (const chunk of [16, 64, 256]) {
    const previewUs = means.get("stream-preview-" + chunk);
    const finalizeUs = means.get("stream-final-" + chunk);
    console.log(JSON.stringify({
      target, chunk, previewUs, finalizeUs, finalOnlySpeedup: Number((previewUs / finalizeUs).toFixed(2)),
    }));
  }
}

function measureReasoning(moduleName, target) {
  const output = runMoon([
    "bench", "--target", target, "--release", "--no-parallelize", "--deny-warn",
    "--package", moduleName, "--file", "think_bench_wbtest.mbt",
  ], target === "native" && Boolean(distribution), repository);
  const toMicros = { ns: 0.001, "µs": 1, "μs": 1, us: 1, ms: 1000, s: 1_000_000 };
  const means = new Map();
  for (const line of output.split(/\r?\n/)) {
    const row = line.match(/^think-(checkpoint|reference|unclosed(?:-small|-reference)?)-(\d+)\s+([\d.]+)\s+(ns|[µμu]s|ms|s)\s+±/);
    if (row) means.set(row[1] + "-" + row[2], Number(row[3]) * toMicros[row[4]]);
  }
  assert.equal(means.size, 13, "Unexpected reasoning benchmark output:\n" + output);
  for (const chunk of [16, 64, 256]) {
    const checkpointUs = means.get("checkpoint-" + chunk);
    const referenceUs = means.get("reference-" + chunk);
    const unclosedUs = means.get("unclosed-" + chunk);
    const unclosedSmallUs = means.get("unclosed-small-" + chunk);
    const unclosedReferenceUs = means.get("unclosed-reference-" + chunk);
    console.log(JSON.stringify({
      target, thinkChunk: chunk, checkpointUs, referenceUs,
      speedup: Number((referenceUs / checkpointUs).toFixed(2)),
      unclosedSmallUs, unclosedUs, unclosedReferenceUs,
      unclosedGrowth: Number((unclosedUs / unclosedSmallUs).toFixed(2)),
      ...(unclosedReferenceUs && { unclosedSpeedup: Number((unclosedReferenceUs / unclosedUs).toFixed(2)) }),
    }));
  }
}

function measureWriteFile(moduleName, target) {
  const output = runMoon([
    "bench", "--target", target, "--release", "--no-parallelize", "--deny-warn",
    "--package", moduleName, "--file", "incremental_bench_test.mbt",
  ], target === "native" && Boolean(distribution), repository);
  const toMicros = { ns: 0.001, "µs": 1, "μs": 1, us: 1, ms: 1000, s: 1_000_000 };
  const means = new Map();
  for (const line of output.split(/\r?\n/)) {
    const row = line.match(/^(write-file-(?:preview|patch)-(?:reference|cached)-\d+-\d+)\s+([\d.]+)\s+(ns|[µμu]s|ms|s)\s+±/);
    if (row) means.set(row[1], Number(row[2]) * toMicros[row[3]]);
  }
  assert.equal(means.size, 16, "Missing write_file benchmark results:\n" + output);
  const round = value => Number(value.toFixed(2));
  for (const bytes of [10_000, 50_000]) {
    for (const chunk of [64, 256]) {
      for (const operation of ["preview", "patch"]) {
        const referenceUs = means.get("write-file-" + operation + "-reference-" + bytes + "-" + chunk);
        const cachedUs = means.get("write-file-" + operation + "-cached-" + bytes + "-" + chunk);
        console.log(JSON.stringify({
          benchmark: "write_file", target, bytes, chunk, operation,
          referenceUs, cachedUs, referenceMBps: round(bytes / referenceUs),
          cachedMBps: round(bytes / cachedUs), speedup: round(referenceUs / cachedUs),
        }));
      }
    }
  }
}

try {
  const manifest = readFileSync(join(repository, "moon.mod"), "utf8");
  const module = manifest.match(/^name\s*=\s*"([^"]+)"/m)?.[1];
  assert.ok(module, "Could not find the MoonBit module name");
  const mod = 'name = "' + module + '"\nversion = "0.1.0"\npreferred_target = "wasm-gc"\n';
  writeFileSync(join(workspace, "moon.mod"), mod);
  writeFileSync(join(workspace, "moon.pkg"), 'import { "moonbitlang/core/json" }\n');
  for (const entry of readdirSync(repository, { withFileTypes: true })) {
    if (entry.isFile() && entry.name.endsWith(".mbt") && !/_(?:test|wbtest)\.mbt$/.test(entry.name)) {
      copyFileSync(join(repository, entry.name), join(workspace, entry.name));
    }
  }
  const bridge = [
    "///|",
    strict,
    "",
    "///|",
    repair,
    "",
    "///|",
    '#export_name("moonStrictRelease")',
    "pub fn strict_entry(source : String) -> String { strict_json(source) }",
    "",
    "///|",
    '#export_name("moonRepairRelease")',
    "pub fn repair_entry(source : String) -> String { repaired_json(source) }",
  ].join("\n");
  makePackage(module, "timing", bridge, true, true);
  makePackage(module, "strict_probe", executableSource(strict, "strict_json"));
  makePackage(module, "repair_probe", executableSource(repair, "repaired_json"), false, true);

  console.log(JSON.stringify({
    moon: runMoon(["version"]).trim(),
    node: process.version,
    cpu: cpus()[0]?.model.trim(),
    host: platform(),
  }));
  const require = createRequire(import.meta.url);
  console.table(measureFixtures(require(compile("timing", "js"))));
  for (const target of targets) {
    const strictSize = fileSizes(compile("strict_probe", target));
    const repairSize = fileSizes(compile("repair_probe", target));
    console.log(JSON.stringify({ target, strict: strictSize, repair: repairSize }));
    measureScaling(module, target);
    measureReasoning(module, target);
    measureWriteFile(module, target);
  }
} finally {
  const target = realpathSync(workspace);
  assert.ok(dirname(target) === tempRoot && basename(target).startsWith(prefix), "Unexpected benchmark scratch directory");
  rmSync(target, { recursive: true, force: true });
}
