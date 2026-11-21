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

async function runSegmentedPipe(args, first, second, closeInput) {
  const child = spawn(command, [...prefix, ...args], {
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
      if (closeInput) child.stdin.end(second);
      else child.stdin.write(second);
    }
  });
  const finished = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.stdin.once("error", reject);
    child.once("close", (status, signal) => resolve({ status, signal }));
  });
  const timer = setTimeout(() => child.kill(), timeout);
  try {
    child.stdin.write(first);
    const { status, signal } = await finished;
    assert.ok(firstLineReceived, "CLI waited for EOF before producing the first report");
    assert.equal(signal, null);
    return { status, stdout, stderr: applicationStderr(stderr) };
  } finally {
    clearTimeout(timer);
    if (child.exitCode === null && child.signalCode === null) child.kill();
  }
}

function sseData(message, newline = "\n") {
  return "data: " + JSON.stringify(message) + newline + newline;
}

function chatArgs(args, { index = 0, choice = 0, id, name, messageId = "chat-1" } = {}) {
  return sseData({
    id: messageId,
    choices: [{
      index: choice,
      delta: {
        reasoning_content: '{"draft":true}',
        content: '{"not_a_tool":true}',
        tool_calls: [{ index, id, function: { name, arguments: args } }],
      },
    }],
  });
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
  const tools = fixture("tool-schemas.json", JSON.stringify({
    write_file: {
      type: "object", properties: { n: { type: "integer", minimum: 0 } }, required: ["n"],
    },
    read_file: {
      type: "object", properties: { path: { type: "string" } }, required: ["path"],
    },
  }));
  const invalidTools = fixture("bad-tool-schemas.json", "[]");
  const mcp = ["--mcp-guard", "--tool-schemas", tools, "--strict-exit"];
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

  await scenario("NDJSON flushes a complete record while stdin remains open", async () => {
    const result = await runSegmentedPipe(["--ndjson", "--strict-exit"], "{}\n", "[]\n", true);
    assert.deepEqual(reports(result, 0).map(({ line, json }) => [line, json]), [[1, "{}"], [2, "[]"]]);
  });

  await scenario("SSE previews stream before EOF and DONE terminates the live process", async () => {
    const result = await runSegmentedPipe(
      ["--sse", "--emit-patches", "--strict-exit", "--schema", schema],
      chatArgs('{"n":9007199254740993', { id: "large", name: "check_amount" }),
      chatArgs("}") + "data: [DONE]\n\n",
      false,
    );
    const [open, closed, final] = reports(result, 0);
    assert.deepEqual([open.event, closed.event, final.event], ["patch", "patch", "tool_call"]);
    assert.deepEqual([open.seq, closed.seq, final.seq], [1, 2, 3]);
    assert.equal(open.call.name, "check_amount");
    assert.equal(open.patches[0].path, "");
    assert.equal(open.fields.find(({ pointer }) => pointer === "/n").sealed, false);
    assert.equal(closed.fields.find(({ pointer }) => pointer === "/n").sealed, true);
    assert.deepEqual(final.patches, []);
    assert.equal(final.json, '{"n":9007199254740993}');
    assert.match(result.stdout, /"value":\{"n":9007199254740993\}/);
    assert.doesNotMatch(result.stdout, /draft|not_a_tool/);
  });

  await scenario("SSE Chat choices preserve independently interleaved calls", () => {
    const input = chatArgs('{"n":', { id: "a" }) +
      chatArgs('{"n":2}', { index: 1, id: "b" }) +
      chatArgs('{"n":3}', { choice: 1, id: "c" }) +
      chatArgs("1}") +
      sseData({
        id: "chat-1",
        choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }],
      }) +
      "data: [DONE]\n\n";
    const rows = reports(run(["--sse", "--strict-exit"], input), 0);
    assert.deepEqual(rows.map(({ call, json, finish_reason }) =>
      [call.choice_index, call.index, call.id, json, finish_reason]), [
      [0, 0, "a", '{"n":1}', "tool_calls"],
      [0, 1, "b", '{"n":2}', "tool_calls"],
      [1, 0, "c", '{"n":3}', "done"],
    ]);
  });

  await scenario("SSE Anthropic CRLF file decodes Unicode deltas and skips thinking", () => {
    const event = (type, data = {}) =>
      "event: " + type + "\r\n" + sseData({ type, ...data }, "\r\n");
    const file = fixture("claude.sse",
      "\ufeff: heartbeat\r\n\r\n" +
      event("message_start", { message: { id: "msg-1" } }) +
      event("content_block_start", {
        index: 1, content_block: { type: "tool_use", id: "u0", name: "lookup", input: {} },
      }) +
      event("content_block_delta", {
        index: 1, delta: { type: "thinking_delta", thinking: '{"draft":1}' },
      }) +
      event("content_block_delta", {
        index: 1, delta: { type: "input_json_delta", partial_json: '{"城市":"上' },
      }) +
      event("content_block_delta", {
        index: 1, delta: { type: "input_json_delta", partial_json: '海🌙"}' },
      }) +
      event("content_block_stop", { index: 1 }) + event("message_stop"));
    const rows = reports(run(["--sse", "--emit-patches", "--strict-exit", file]), 0);
    assert.deepEqual(rows.map(({ event }) => event), ["patch", "patch", "tool_call"]);
    assert.deepEqual(rows.at(-1).call, {
      provider: "anthropic_messages", message_id: "msg-1", index: 1, id: "u0", name: "lookup",
    });
    assert.equal(rows.at(-1).json, '{"城市":"上海🌙"}');
    assert.equal(rows[1].patches[0].path, "/城市");
    assert.equal(rows[1].fields.find(({ pointer }) => pointer === "/城市").sealed, true);
  });

  await scenario("SSE Anthropic message stop terminates a pipe with stdin open", async () => {
    const result = await runSegmentedPipe(
      ["--sse", "--emit-patches", "--strict-exit"],
      sseData({
        type: "content_block_delta", index: 0,
        delta: { type: "input_json_delta", partial_json: '{"ready":true}' },
      }),
      sseData({ type: "message_stop" }),
      false,
    );
    const [preview, final] = reports(result, 0);
    assert.equal(preview.event, "patch");
    assert.equal(final.finish_reason, "message_stop");
    assert.equal(final.json, '{"ready":true}');
  });

  await scenario("SSE provider faults take precedence and final Schema rules control strict status", () => {
    const args = ["--sse", "--strict-exit", "--schema", schema, "--retry-prompt"];
    const valid = chatArgs('{"n":1}');
    const invalid = chatArgs('{"n":-1}', { index: 1 });
    const done = "data: [DONE]\n\n";
    const [ok, rejected] = reports(run(args, valid + invalid + done), 3);
    assert.equal(ok.status, 0);
    assert.equal(rejected.status, 3);
    assert.match(rejected.retry_prompt, /\$\.n/);
    const [fault, final] = reports(run(args, "data: invalid\n\n" + invalid + done), 1);
    assert.equal(fault.error.kind, "sse_json");
    assert.equal(final.status, 3);
    const [eofError, eofFinal] = reports(run(args, valid + "data: [DONE]"), 1);
    assert.equal(eofError.error.kind, "sse_truncated_event");
    assert.equal(eofFinal.finish_reason, "eof");
    errorReport(run(["--emit-patches"]), 2, "usage");
    errorReport(run(["--sse", "--ndjson"]), 2, "usage");
  });

  await scenario("MCP forwards exact requests and notifications before EOF", async () => {
    const initialize = '  {"jsonrpc":"2.0","id":9007199254740993,"method":"initialize","params":{}} \t';
    const notify = '{"jsonrpc":"2.0","method":"notifications/initialized"}';
    const result = await runSegmentedPipe(mcp, initialize + "\r\n", notify + "\n", true);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, "");
    assert.equal(result.stdout, initialize + "\n" + notify + "\n");
  });

  await scenario("MCP file input routes multiple schemas and keeps large numeric lexemes", () => {
    const write = '{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"write_file","arguments":"{\\"n\\":\\"9007199254740993\\""}';
    const read = '{"jsonrpc":"2.0","id":"read","method":"tools/call","params":{"name":"read_file","arguments":{"path":"src/main.mbt"}}}';
    const input = fixture("mcp.ndjson", write + "\r\n" + read);
    const result = run([...mcp, "--coerce", input]);
    const [repaired, forwarded] = reports(result, 0);
    assert.equal(repaired.params.name, "write_file");
    assert.match(result.stdout, /"id":9007199254740993/);
    assert.match(result.stdout, /"arguments":\{"n":9007199254740993\}/);
    assert.equal(forwarded.params.arguments.path, "src/main.mbt");
    assert.equal(result.stdout.split("\n")[1], read);
  });

  await scenario("MCP rejects invalid parameters and suppresses tool notifications", () => {
    const invalid = '{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"write_file","arguments":{"n":-1}}}';
    const notification = '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"write_file","arguments":{"n":1}}}';
    const result = run(mcp, invalid + "\n" + notification + "\n");
    const rows = reports(result, 3);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].jsonrpc, "2.0");
    assert.equal(rows[0].error.code, -32602);
    assert.equal(rows[0].error.data.issues[0].path, "$.params.arguments.n");
    assert.match(rows[0].error.data.retry_prompt, /\$\.n/);
    assert.match(result.stdout, /"id":9007199254740993/);
    assert.deepEqual(reports(run(mcp.slice(0, -1), invalid + "\n"), 0), rows);
  });

  await scenario("MCP resumes after malformed UTF-8 and invalid transport records", () => {
    const invalid = '{"jsonrpc":"2.0","id":"bad","method":"tools/call","params":{"name":"write_file","arguments":{"n":-1}}}';
    const input = Buffer.concat([
      Buffer.of(0xff, 0x0a),
      Buffer.from(invalid + '\n{"jsonrpc":"2.0","id":"ok","method":"tools/list"}\n'),
    ]);
    const rows = reports(run(mcp, input), 1);
    assert.equal(rows[0].id, null);
    assert.equal(rows[0].error.code, -32700);
    assert.equal(rows[0].error.data.kind, "invalid_utf8");
    assert.equal(rows[1].error.code, -32602);
    assert.equal(rows[2].method, "tools/list");
  });

  await scenario("MCP validates the registry once and keeps startup errors on stderr", () => {
    errorReport(run(["--mcp-guard"]), 2, "usage");
    errorReport(run(["--mcp-guard", "--tool-schemas", invalidTools], "{}\n"), 1, "tool_schemas");
    errorReport(run(["--mcp-guard", "--tool-schemas", malformedSchema], "{}\n"), 1, "schema_parse");
    errorReport(run([...mcp, "--sse"]), 2, "usage");
  });
  console.log(`Native CLI process scenarios: ${passed}/${passed} passed.`);
} finally {
  for (const path of fixtures) unlinkSync(path);
  rmdirSync(scratch);
}
