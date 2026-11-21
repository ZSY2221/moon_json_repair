import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";
import { performance } from "node:perf_hooks";

const repository = fileURLToPath(new URL("../", import.meta.url));
const [mode, flag, distribution, ...extra] = process.argv.slice(2);
const backends = ["wasm-gc", "js", "native"];
if (extra.length || (mode && !backends.includes(mode) && mode !== "--browser") ||
    (flag && (mode !== "native" || flag !== "--native-wsl" || !distribution || process.platform !== "win32")) ||
    (mode === "native" && process.platform === "win32" && !distribution)) {
  throw new Error("Usage: node tools/verify-examples.mjs [wasm-gc|js|native|--browser] [--native-wsl DISTRO]");
}
const read = path => readFileSync(path, "utf8").replaceAll("\r\n", "\n");
const lines = output => output.replaceAll("\r\n", "\n").trimEnd().split("\n");
const example = name => join(repository, "examples", name);
const mcpDirectory = "examples/03-mcp-guard-pipeline";

function runMoon(args, cwd) {
  const options = { cwd, encoding: "utf8", timeout: 120_000, env: { ...process.env, WSL_UTF8: "1" } };
  let run = distribution
    ? spawnSync("wsl.exe", ["-d", distribution, "-e", "bash", "-lc",
      'export PATH="$HOME/.moon/bin:$PATH"; exec moon "$@"', "moon", ...args], options)
    : spawnSync("moon", args, options);
  if (!distribution && run.error?.code === "ENOENT") {
    const executable = process.platform === "win32" ? "moon.exe" : "moon";
    run = spawnSync(join(homedir(), ".moon", "bin", executable), args, options);
  }
  if (run.error) throw run.error;
  assert.equal(run.status, 0, "moon " + args.join(" ") + "\n" + run.stdout + run.stderr);
  return run.stdout;
}

function verifyConsumer(target) {
  const buildDir = join(repository, "_build");
  mkdirSync(buildDir, { recursive: true });
  const root = realpathSync(buildDir);
  const prefix = "examples-consumer-";
  const temp = mkdtempSync(join(root, prefix));
  try {
    const library = join(temp, "library");
    const consumer = join(temp, "consumer");
    mkdirSync(library);
    for (const entry of readdirSync(repository, { withFileTypes: true })) {
      if (!entry.isFile()) continue;
      if ((entry.name.endsWith(".mbt") && !/_(?:wb)?test\.mbt$/.test(entry.name)) ||
          ["moon.mod", "moon.pkg", "README.md"].includes(entry.name)) {
        copyFileSync(join(repository, entry.name), join(library, entry.name));
      }
    }
    mkdirSync(consumer);
    for (const name of ["moon.mod", "moon.pkg", "main.mbt"]) {
      copyFileSync(join(example("01-moonbit-agent-gateway"), name), join(consumer, name));
    }
    const version = read(join(library, "moon.mod")).match(/^version = "([^"]+)"/m)?.[1];
    assert.ok(version);
    assert.ok(read(join(consumer, "moon.mod")).includes('"ZSY2221/json_repair@' + version + '"'),
      "The independent example should pin the checked-out module version.");
    writeFileSync(join(temp, "moon.work"), 'members = ["library", "consumer"]\n');
    const output = lines(runMoon(["run", "--target", target, "--deny-warn", "consumer"], temp));
    assert.match(output[0], /"order_id":9007199254740993(?=[,}])/);
    const recovered = JSON.parse(output[0]);
    assert.equal(recovered.user_name, "Ada 🙂");
    assert.ok(!Object.hasOwn(recovered, "userName"));
    assert.equal(recovered.currency, "USD");
    assert.equal(recovered.amount_cents, -25);
    const feedback = output.slice(1).join("\n");
    assert.match(feedback, /error\[minimum\]/);
    assert.match(feedback, /UTF-16/);
    assert.match(feedback, /\^/);
    const retry = JSON.parse(output.at(-1));
    assert.deepEqual(retry.fix.map(({ path, actual, example }) => ({ path, actual, example })), [
      { path: "$.amount_cents", actual: -25, example: 1 },
    ]);
    assert.ok(!output.join("\n").includes("Draft account lookup"));
  } finally {
    const created = realpathSync(temp);
    assert.ok(dirname(created) === root && basename(created).startsWith(prefix));
    rmSync(created, { recursive: true, force: true, maxRetries: 4, retryDelay: 100 });
  }
  console.log("MoonBit agent gateway: independent " + target + " recovery, diagnostic and retry passed.");
}

async function verifyBrowser() {
  const directory = example("02-browser-wasm-gc");
  const html = read(join(directory, "index.html"));
  const scriptPaths = [...html.matchAll(/<script src="([^"]+)" defer><\/script>/g)].map(match => match[1]);
  assert.deepEqual(scriptPaths, ["../../web/engine-wasm.js", "./stream.js"]);
  assert.ok(!/\b(?:src|href)=["'](?:[a-z]+:|\/\/|\/)/i.test(html));
  const elements = new Map(["#run", "#status", "#output"].map(selector => [selector, { textContent: "" }]));
  let click;
  elements.get("#run").addEventListener = (event, listener) => {
    assert.equal(event, "click");
    click = listener;
  };
  const realm = {
    WebAssembly, Uint8Array, atob, performance,
    document: { querySelector: selector => elements.get(selector) },
    setTimeout: callback => callback(),
    fetch: () => assert.fail("The file:// example must work without a network fetch."),
  };
  for (const path of scriptPaths) {
    runInNewContext(read(resolve(directory, path)), realm);
  }
  const { loadWasmRepair, repairChunked, chunks } =
    runInNewContext("({loadWasmRepair, repairChunked, chunks})", realm);
  const engine = await loadWasmRepair();
  const outcomes = Array.from(repairChunked(engine, chunks));
  assert.equal(outcomes.length, 4);
  assert.ok(outcomes.every(({ elapsedMs }) => Number.isFinite(elapsedMs) && elapsedMs >= 0));
  const last = outcomes.at(-1).frame;
  assert.equal(last.stream.finalized, true);
  assert.equal(last.blocks[0].report.json, '{"tool":"write_file","args":{"id":9007199254740993,"path":"report.md"}}');
  assert.match(outcomes[2].frame.blocks[0].report.json, /"id":9007199254740993(?=[,}])/);
  assert.ok(!outcomes[0].frame.stream.finalized);
  await click();
  assert.equal(elements.get("#run").disabled, false);
  assert.match(elements.get("#status").textContent, /^4\/4 chunks/);
  assert.equal(elements.get("#output").textContent, last.blocks[0].report.json);
  console.log("Browser Wasm GC: four offline stream snapshots and exact wide integer passed.");
  const registry = read(join(repository, mcpDirectory, "tools.json"));
  const requests = lines(read(join(repository, mcpDirectory, "requests.ndjson")));
  const decisions = requests.map(source => JSON.parse(engine.moonLabGuardMcp(source, registry, false, true, false)));
  assert.deepEqual(decisions.map(({ forward }) => forward), [true, true, true, false]);
  assertMcpFrames(decisions.map(({ frame }) => frame), requests);
  console.log("MCP frames: four routing outcomes passed on the compiled Wasm GC bridge.");
}

function assertMcpFrames(output, fixtureLines) {
  assert.equal(output.length, 4);
  assert.equal(output[0], fixtureLines[0]);
  assert.equal(output[1], fixtureLines[1]);
  assert.match(output[2], /"order_id":9007199254740993(?=[,}])/);
  assert.equal(JSON.parse(output[2]).params.arguments.amount_cents, 1250);
  const rejection = JSON.parse(output[3]);
  assert.equal(rejection.jsonrpc, "2.0");
  assert.equal(rejection.id, "amount-1");
  assert.equal(rejection.error.code, -32602);
  assert.ok(rejection.error.data.issues.some(issue => issue.path === "$.params.arguments.amount_cents"));
  assert.match(rejection.error.data.retry_prompt, /amount_cents/);
}

function verifyNativePipeline() {
  const input = read(join(repository, mcpDirectory, "requests.ndjson"));
  const fixtureLines = lines(input);
  // Run the compiled executable directly so this tests the application's
  // exit status rather than the toolchain's handling of a non-zero child.
  const buildArgs = ["build", "--target", "native", "--deny-warn", "--output-json"];
  if (distribution) {
    const workspaceKey = createHash("sha256").update(repository).digest("hex").slice(0, 12);
    buildArgs.push("--target-dir", "/tmp/moon-json-repair-examples-" + workspaceKey);
  }
  const build = runMoon([...buildArgs, "cmd/main"], repository);
  const artifact = lines(build).filter(line => line.startsWith("{")).map(line => JSON.parse(line))
    .find(message => message.$message_type === "artifact" &&
      message.target_backend === "native" && message.package.endsWith("/cmd/main"));
  assert.ok(artifact?.path, "Native CLI build did not report an executable.");
  const args = ["--mcp-guard", "--tool-schemas", mcpDirectory + "/tools.json",
    "--coerce", "--strict-exit"];
  const options = { cwd: repository, encoding: "utf8", input, timeout: 15_000, env: { ...process.env, WSL_UTF8: "1" } };
  const run = distribution
    ? spawnSync("wsl.exe", ["-d", distribution, "--exec", artifact.path, ...args], options)
    : spawnSync(artifact.path, args, options);
  if (run.error) throw run.error;
  assert.equal(run.status, 3, run.stdout + run.stderr);
  assertMcpFrames(lines(run.stdout), fixtureLines);
  console.log("MCP Native pipeline: four routing outcomes, exact ID, retry and exit 3 passed.");
}

if (mode === "--browser" || !mode) await verifyBrowser();
if (mode !== "--browser") {
  for (const target of mode ? [mode] : ["wasm-gc", "js"]) verifyConsumer(target);
}
if (mode === "native") verifyNativePipeline();
