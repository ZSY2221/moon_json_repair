import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmdirSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const binary = args[0] && !args[0].startsWith("--") ? args.shift() : undefined;
const [flag, distro, ...extra] = args;
if (extra.length || (flag && (flag !== "--native-wsl" || !distro || process.platform !== "win32"))) {
  throw new Error("Usage: node tools/cli-smoke.mjs [native executable] [--native-wsl DISTRO]");
}
if (!binary && !distro && process.platform === "win32") {
  throw new Error("Supply an existing executable or explicitly choose --native-wsl DISTRO on Windows.");
}

const project = fileURLToPath(new URL("../", import.meta.url));
const buildDir = join(project, "_build");
const env = { ...process.env, WSL_UTF8: "1" };
const timeout = 15_000;

function targetPath(path) {
  if (!distro) return resolve(path);
  if (path.startsWith("/")) return path;
  const result = spawnSync("wsl.exe", ["-d", distro, "--exec", "wslpath", "-a", resolve(path)], {
    cwd: project, env, encoding: "utf8", timeout,
  });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

// WSL can write a proxy notice to stderr before forwarding the child streams.
function applicationStderr(stderr) {
  if (!distro) return stderr;
  return stderr.replaceAll("\0", "").replace(/^wsl:[^\r\n]*\r?\n/gm, "");
}

function buildNative() {
  const projectHash = createHash("sha256").update(project).digest("hex").slice(0, 12);
  // Keep WSL compilation inside the selected distro's Linux filesystem.
  const targetDir = distro ? `/tmp/moon-json-repair-cli-smoke-${projectHash}` : join(buildDir, "cli-smoke-native");
  const args = ["build", "--target", "native", "--deny-warn", "--output-json", "--target-dir", targetDir, "cmd/main"];
  const options = { cwd: project, env, encoding: "utf8", timeout: 120_000 };
  let result = distro
    ? spawnSync("wsl.exe", ["-d", distro, "--exec", "bash", "-lc",
      'export PATH="$HOME/.moon/bin:$PATH"; exec moon "$@"', "moon", ...args], options)
    : spawnSync("moon", args, options);
  if (!distro && result.error?.code === "ENOENT") {
    result = spawnSync(join(homedir(), ".moon", "bin", "moon"), args, options);
  }
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stdout + applicationStderr(result.stderr));
  const artifact = result.stdout.split("\n")
    .filter((line) => line.startsWith("{"))
    .map((line) => JSON.parse(line))
    .find((message) => message.$message_type === "artifact" &&
      message.target_backend === "native" && message.package.endsWith("/cmd/main"));
  assert.ok(artifact?.path, "Native CLI build did not report an executable artifact");
  return artifact.path;
}

const executable = binary ? targetPath(binary) : buildNative();
const command = distro ? "wsl.exe" : executable;
const prefix = distro ? ["-d", distro, "--exec", executable] : [];

function run(args, input = "") {
  const result = spawnSync(command, [...prefix, ...args], {
    cwd: project, env, input, encoding: "utf8", timeout,
  });
  if (result.error) throw result.error;
  assert.equal(result.signal, null);
  return { stdout: result.stdout, stderr: applicationStderr(result.stderr), status: result.status };
}

function reports(result, status) {
  assert.equal(result.status, status, result.stderr);
  assert.equal(result.stderr, "");
  assert.ok(result.stdout.endsWith("\n"));
  return result.stdout.trimEnd().split("\n").map((line) => JSON.parse(line));
}

function errorReport(result, status, kind) {
  assert.equal(result.status, status);
  assert.equal(result.stdout, "");
  assert.equal(JSON.parse(result.stderr).error.kind, kind);
}

async function verifyLivePipe() {
  const child = spawn(command, [...prefix, "--ndjson", "--strict-exit"], {
    cwd: project, env, stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  let firstLineReceived = false;
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
    if (!firstLineReceived && stdout.includes("\n")) {
      firstLineReceived = true;
      child.stdin.end("[]\n");
    }
  });
  const finished = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.stdin.once("error", reject);
    child.once("close", (status, signal) => resolve({ status, signal }));
  });
  const timer = setTimeout(() => child.kill(), timeout);
  try {
    child.stdin.write("{}\n");
    const { status, signal } = await finished;
    assert.ok(firstLineReceived, "CLI waited for EOF before producing the first report");
    assert.equal(signal, null);
    assert.deepEqual(reports({ status, stdout, stderr: applicationStderr(stderr) }, 0)
      .map(({ line, json }) => [line, json]), [[1, "{}"], [2, "[]"]]);
  } finally {
    clearTimeout(timer);
    if (child.exitCode === null && child.signalCode === null) child.kill();
  }
}

mkdirSync(buildDir, { recursive: true });
const scratch = mkdtempSync(join(buildDir, "cli-smoke-"));
const fixtures = [];
function fixture(name, contents) {
  const path = join(scratch, name);
  writeFileSync(path, contents);
  fixtures.push(path);
  return targetPath(path);
}

let passed = 0;
async function scenario(name, verify) {
  await verify();
  passed += 1;
  console.log(`PASS ${name}`);
}

try {
  const schema = fixture("schema.json", '{"type":"object","properties":{"n":{"type":"integer","minimum":0}},"required":["n"]}');
  const malformedSchema = fixture("malformed-schema.json", '{"missing":');
  const batchText = '{"n":9007199254740993\r\n\r\n{"n":-1}\n{"n":2,}';
  const batch = fixture("input.ndjson", batchText);
  const input = fixture("input.json", '{"n":4,}');

  await scenario("legacy stdin envelope and exact integer", () => {
    const result = run(["-"], '{"n":9007199254740993');
    const [report] = reports(result, 0);
    assert.deepEqual(Object.keys(report).sort(), ["edits", "json", "schema", "value"]);
    assert.equal(report.schema, null);
    assert.equal(report.json, '{"n":9007199254740993}');
    assert.match(result.stdout, /"value":\{"n":9007199254740993\}/);
  });

  await scenario("legacy file input and code 3 for schema failure", () => {
    const [repaired] = reports(run([input]), 0);
    assert.equal(repaired.json, '{"n":4}');
    const [invalid] = reports(run(["--schema", schema], '{"n":-1}'), 3);
    assert.equal(invalid.schema.errors[0].path, "$.n");
  });

  await scenario("NDJSON stdin continues after syntax and schema failures", () => {
    const result = run(["--ndjson", "--schema", schema], batchText);
    const batch = reports(result, 0);
    assert.deepEqual(batch.map(({ line, status, ok }) => [line, status, ok]),
      [[1, 0, true], [2, 1, false], [3, 3, false], [4, 0, true]]);
    assert.equal(batch[1].error.kind, "empty_input");
    assert.equal(batch[2].schema.errors[0].path, "$.n");
    assert.equal(batch[3].json, '{"n":2}');
    assert.match(result.stdout, /"value":\{"n":9007199254740993\}/);
  });

  await scenario("NDJSON file input, strict error precedence, and identical records", () => {
    const loose = run(["--ndjson", "--schema", schema], batchText);
    const strict = run(["--ndjson", "--strict-exit", "--schema", schema, batch]);
    assert.deepEqual(reports(strict, 1), reports(loose, 0));
    assert.equal(strict.stdout, loose.stdout);
  });

  await scenario("NDJSON strict code 3 for schema alone and code 0 on success", () => {
    const args = ["--ndjson", "--strict-exit", "--schema", schema];
    assert.deepEqual(reports(run(args, '{"n":-1}\n{"n":2}\n'), 3).map(({ status }) => status), [3, 0]);
    assert.deepEqual(reports(run(args, '{"n":2}\n'), 0).map(({ status }) => status), [0]);
  });

  await scenario("reasoning skip, multiple blocks, wide coercion, and retry prompt", () => {
    const args = ["--extract-all", "--ignore-think", "--schema", schema, "--coerce", "--retry-prompt"];
    const result = run(args, '<tHiNk>{"n":0}</ThINk>{"n":"9007199254740993"}{"n":-1');
    const [{ blocks }] = reports(result, 3);
    assert.equal(blocks.length, 2);
    assert.equal(blocks[0].json, '{"n":9007199254740993}');
    assert.match(result.stdout, /"value":\{"n":9007199254740993\}/);
    assert.equal(blocks[0].coercions[0].path, "$.n");
    assert.equal(blocks[0].retry_prompt, "");
    assert.equal(blocks[1].schema.valid, false);
    assert.match(blocks[1].retry_prompt, /\$\.n/);
    errorReport(run(["--extract-all", "--ignore-think"], '<think>{"n":0}'), 1, "no_blocks");
  });

  await scenario("invalid UTF-8 and oversized physical lines resume at next LF", () => {
    const input = Buffer.concat([Buffer.of(0xff, 0x0a), Buffer.alloc(3 * 1024 * 1024 + 32, 0x78), Buffer.from("\n{}\n")]);
    const batch = reports(run(["--ndjson", "--strict-exit"], input), 1);
    assert.deepEqual(batch.map(({ line, status }) => [line, status]), [[1, 1], [2, 1], [3, 0]]);
    assert.equal(batch[0].error.kind, "invalid_utf8");
    assert.equal(batch[1].error.kind, "input_limit");
  });

  await scenario("global I/O/schema rejection and usage codes", () => {
    errorReport(run(["--ndjson", "--schema", malformedSchema], "{}\n"), 1, "schema_parse");
    errorReport(run(["--ndjson", targetPath(join(scratch, "absent.json"))]), 1, "io");
    errorReport(run(["--coerce"], "{}"), 2, "usage");
    errorReport(run(["--unknown"]), 2, "usage");
  });

  await scenario("NDJSON flushes a complete record while stdin remains open", verifyLivePipe);
  console.log(`Native CLI process scenarios: ${passed}/${passed} passed.`);
} finally {
  for (const path of fixtures) unlinkSync(path);
  rmdirSync(scratch);
}
