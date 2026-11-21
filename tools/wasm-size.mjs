import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const repo = fileURLToPath(new URL("../", import.meta.url));
const [flag, revision, ...extra] = process.argv.slice(2);
if (extra.length || (flag !== undefined && (flag !== "--baseline" || !revision || revision.startsWith("-")))) {
  throw new Error("Usage: node tools/wasm-size.mjs [--baseline GIT_REVISION]");
}
const abi = { builtins: ["js-string"], importedStringConstants: "_" };
const sectionNames = [
  "custom", "type", "import", "function", "table", "memory", "global",
  "export", "start", "element", "code", "data", "data_count", "tag",
];

function run(command, args, cwd) {
  const options = { cwd, encoding: "utf8" };
  let output = spawnSync(command, args, options);
  if (command === "moon" && output.error?.code === "ENOENT") {
    const binary = process.platform === "win32" ? "moon.exe" : "moon";
    output = spawnSync(join(homedir(), ".moon", "bin", binary), args, options);
  }
  if (output.error || output.status !== 0) {
    throw output.error ?? new Error(command + " " + args.join(" ") + "\n" + output.stdout + output.stderr);
  }
  return output.stdout;
}

function build(cwd, pkg, targetDir, strip) {
  const output = run("moon", [
    "build", pkg, "--target", "wasm-gc", "--release", strip ? "--strip" : "--no-strip",
    "--deny-warn", "--output-json", "--target-dir", targetDir,
  ], cwd);
  const result = output.split(/\r?\n/).filter((line) => line.startsWith("{"))
    .map((line) => JSON.parse(line))
    .find((message) => message.$message_type === "artifact" && message.target_backend === "wasm-gc"
      && message.package.endsWith("/" + pkg));
  assert.ok(result, "Compiler did not report Wasm GC artifact for " + pkg);
  return readFileSync(result.path);
}

function readCarrier(carrier) {
  const match = carrier.match(/\bbase64:\s*"([A-Za-z0-9+/=]+)"/);
  assert.ok(match, "No embedded Wasm payload found");
  return Buffer.from(match[1], "base64");
}

// Section lengths include their IDs and length prefixes. Compressed sizes are
// reported for whole modules since gzip is not additive across sections.
function inspectSections(bytes) {
  assert.deepEqual([...bytes.subarray(0, 8)], [0, 97, 115, 109, 1, 0, 0, 0]);
  let cursor = 8;
  function readVarUint(limit) {
    let value = 0;
    for (let bit = 0; bit <= 28; bit += 7) {
      assert.ok(cursor < limit, "Truncated section length or custom name");
      const byte = bytes[cursor++];
      assert.ok(bit < 28 || byte < 16, "Invalid variable-length u32");
      value += (byte & 0x7f) * 2 ** bit;
      if ((byte & 0x80) === 0) return value;
    }
    throw new Error("Invalid variable-length u32");
  }
  const sections = { header: cursor };
  while (cursor < bytes.length) {
    const start = cursor;
    const id = bytes[cursor++];
    const length = readVarUint(bytes.length);
    const end = cursor + length;
    assert.ok(end <= bytes.length, "Section extends beyond module");
    let name = sectionNames[id] ?? "section_" + id;
    if (id === 0) {
      const nameLength = readVarUint(end);
      assert.ok(cursor + nameLength <= end, "Custom section name extends beyond section");
      name += ":" + bytes.toString("utf8", cursor, cursor + nameLength);
    }
    sections[name] = (sections[name] ?? 0) + end - start;
    cursor = end;
  }
  assert.equal(Object.values(sections).reduce((total, count) => total + count, 0), bytes.length);
  return sections;
}

async function measure(name, bytes) {
  const module = await WebAssembly.compile(bytes, abi);
  return {
    name, raw: bytes.length, gzip: gzipSync(bytes, { level: 9 }).length,
    exports: WebAssembly.Module.exports(module).map(({ name }) => name),
    hostImports: WebAssembly.Module.imports(module),
    sections: inspectSections(bytes),
  };
}

function createMinimalProbe(workspace) {
  const path = join(workspace, "minimal");
  const pkg = join(path, "probe");
  mkdirSync(pkg, { recursive: true });
  for (const { name } of readdirSync(repo, { withFileTypes: true }).filter((entry) => entry.isFile())) {
    if (name === "moon.mod" || name === "moon.pkg" || (name.endsWith(".mbt") && !/_(?:test|wbtest)\.mbt$/.test(name))) {
      copyFileSync(join(repo, name), join(path, name));
    }
  }
  const manifest = readFileSync(join(path, "moon.mod"), "utf8");
  const name = manifest.match(/^name\s*=\s*"([^"]+)"$/m)?.[1];
  assert.ok(name, "Missing module name");
  writeFileSync(join(pkg, "moon.pkg"), `import { "${name}" @repair }
pkgtype(kind: "foreign_library")
supported_targets = "wasm-gc"
options(link: { "wasm-gc": { "use-js-builtin-string": true, "imported-string-constants": "_" } })
`);
  writeFileSync(join(pkg, "probe.mbt"), `///|
#export_name("moonRepairSizeProbe")
pub fn repair_payload(source : String) -> String {
  match @repair.repair(source) {
    Ok(report) => report.json
    Err(_) => ""
  }
}
`);
  return path;
}

const buildDir = join(repo, "_build");
mkdirSync(buildDir, { recursive: true });
const root = realpathSync(buildDir);
const prefix = "wasm-size-";
const workspace = mkdtempSync(join(root, prefix));
try {
  const stripped = build(repo, "cmd/playground", join(workspace, "stripped"), true);
  const unstripped = build(repo, "cmd/playground", join(workspace, "unstripped"), false);
  const probeRoot = createMinimalProbe(workspace);
  const probe = build(probeRoot, "probe", join(workspace, "probe-build"), true);
  const { instance } = await WebAssembly.instantiate(probe, {}, abi);
  assert.equal(instance.exports.moonRepairSizeProbe('{"id":9007199254740993'), '{"id":9007199254740993}');
  const records = [];
  if (revision) {
    const carrier = run("git", ["show", revision + ":web/engine-wasm.js"], repo);
    records.push(await measure("baseline " + revision, readCarrier(carrier)));
  }
  records.push(
    await measure("current release", stripped),
    await measure("current release without stripping", unstripped),
    await measure("minimal repair export", probe),
  );
  console.log(JSON.stringify({ compiler: run("moon", ["version"], repo).trim(), records }, null, 2));
} finally {
  const resolved = realpathSync(workspace);
  assert.equal(dirname(resolved), root);
  assert.ok(basename(resolved).startsWith(prefix));
  rmSync(resolved, { recursive: true, force: true, maxRetries: 4, retryDelay: 100 });
}
