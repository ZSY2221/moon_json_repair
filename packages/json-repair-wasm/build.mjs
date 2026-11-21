import { spawnSync } from "node:child_process";
import { copyFileSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = new URL("../../", import.meta.url);
const manifest = readFileSync(new URL("moon.mod", root), "utf8");
const { version } = JSON.parse(readFileSync(new URL("package.json", import.meta.url), "utf8"));
if (manifest.match(/^version\s*=\s*"([^"]+)"/m)?.[1] !== version) {
  throw new Error("MoonBit and npm package versions must match.");
}

const args = [
  "build", "cmd/playground", "--target", "wasm-gc", "--release",
  "--strip", "--deny-warn", "--output-json", "--target-dir", "_build/npm-wasm",
];
const options = { cwd: fileURLToPath(root), encoding: "utf8" };
let build = spawnSync("moon", args, options);
if (build.error?.code === "ENOENT") {
  const executable = process.platform === "win32" ? "moon.exe" : "moon";
  build = spawnSync(join(homedir(), ".moon", "bin", executable), args, options);
}
if (build.error) throw build.error;
if (build.stderr) process.stderr.write(build.stderr);
if (build.status !== 0) {
  throw new Error(`Wasm GC build failed.\n${build.stdout}`);
}

const artifact = build.stdout.split(/\r?\n/)
  .filter(line => line.startsWith("{"))
  .map(line => JSON.parse(line))
  .find(message => message.$message_type === "artifact" &&
    message.target_backend === "wasm-gc" && message.package.endsWith("/cmd/playground"));
if (!artifact) throw new Error(`MoonBit did not report the SDK module.\n${build.stdout}`);
const wasm = new URL("engine.wasm", import.meta.url);
copyFileSync(artifact.path, wasm);
copyFileSync(new URL("LICENSE", root), new URL("LICENSE", import.meta.url));
console.log(`Built Wasm GC SDK ${version}: ${readFileSync(wasm).length} bytes.`);
