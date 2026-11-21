import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repository = fileURLToPath(new URL("../", import.meta.url));
const manifest = readFileSync(join(repository, "moon.mod"), "utf8");
const module = /^name\s*=\s*"([^"]+)"/m.exec(manifest)?.[1];
assert.ok(module);
const buildDir = join(repository, "_build");
mkdirSync(buildDir, { recursive: true });
const root = realpathSync(buildDir);
const prefix = "core-coverage-";
const temp = mkdtempSync(join(root, prefix));

function moon(...args) {
  const child = spawnSync("moon", args, { cwd: repository, stdio: "inherit" });
  if (child.error || child.status !== 0) throw child.error ?? new Error("moon exited with status " + child.status);
}

try {
  moon("test", "--target", "wasm-gc", "--deny-warn", "--enable-coverage", "--target-dir", temp);
  const files = readdirSync(temp).filter(name => /^moonbit_coverage_.*\.txt$/.test(name));
  const counters = {};
  const bounds = /----- BEGIN MOONBIT COVERAGE -----\s*([\s\S]*?)\s*----- END MOONBIT COVERAGE -----/g;
  for (const file of files) {
    const text = readFileSync(join(temp, file), "utf8");
    for (const part of text.matchAll(bounds)) {
      for (const [key, points] of Object.entries(JSON.parse(part[1]))) {
        if (!key.startsWith(module + "$")) continue;
        const observed = points.map(count => Number(count > 0));
        if (!counters[key]) counters[key] = observed;
        else {
          assert.equal(counters[key].length, observed.length, "Inconsistent instrumentation for " + key);
          for (let i = 0; i < observed.length; i++) counters[key][i] |= observed[i];
        }
      }
    }
  }
  assert.ok(Object.keys(counters).length, "No counters for the root repair package");
  const runtime = join(temp, "core-runtime.log");
  writeFileSync(runtime, "----- BEGIN MOONBIT COVERAGE -----\n" + JSON.stringify(counters) + "\n----- END MOONBIT COVERAGE -----\n");
  const trace = join(temp, "wasm-gc", "debug", "test", module.split("/").at(-1) + ".trace.source");
  moon("coverage", "report", "--format", "full_summary", "--package", module, "--runtime-log", runtime, trace);
} finally {
  const resolved = realpathSync(temp);
  assert.equal(dirname(resolved), root);
  assert.ok(basename(resolved).startsWith(prefix));
  rmSync(resolved, { recursive: true, force: true, maxRetries: 4, retryDelay: 100 });
}
