import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repository = fileURLToPath(new URL("../", import.meta.url));
const librarySource = resolve(process.argv[2] ?? repository);
const target = process.argv[3] ?? "wasm-gc";
const [flag, distribution, ...extra] = process.argv.slice(4);
if (extra.length || (flag && (flag !== "--native-wsl" || !distribution || target !== "native" || process.platform !== "win32"))) {
  throw new Error("Usage: node tools/verify-readme.mjs [module-dir] [target] [--native-wsl DISTRO]");
}
const read = (path) => readFileSync(path, "utf8").replaceAll("\r\n", "\n");

const moduleConfig = read(join(librarySource, "moon.mod"));
const moduleName = moduleConfig.match(/^name\s*=\s*"([^"]+)"$/m)?.[1];
const version = moduleConfig.match(/^version\s*=\s*"([^"]+)"$/m)?.[1];
if (!moduleName || !version) throw new Error("Missing library module name or version.");

const markdown = read(join(librarySource, "README.md"));
const code = [...markdown.matchAll(/^```(?:moonbit|mbt)\n([\s\S]*?)^```/gm)].map((match) => match[1].trim());
const manifests = code.filter((block) => block.startsWith("import {"));
const examples = code.filter((block) => !block.startsWith("import {"));
if (manifests.length !== 1 || examples.length === 0) {
  throw new Error("Expected one consumer package manifest and at least one API example in README.md.");
}

const doctests = [...read(join(librarySource, "README.mbt.md")).matchAll(/^```mbt check\n([\s\S]*?)^```/gm)]
  .map((match) => match[1].trim());
const withoutBlockMarker = (block) => block.replace(/^\/\/\/\|\n/, "");
if (JSON.stringify(examples.map(withoutBlockMarker)) !== JSON.stringify(doctests.map(withoutBlockMarker))) {
  throw new Error("README.md API examples differ from README.mbt.md.");
}

function runMoon(args, cwd) {
  const options = { cwd, stdio: "inherit", env: { ...process.env, WSL_UTF8: "1" } };
  let result = distribution
    ? spawnSync("wsl.exe", ["-d", distribution, "-e", "bash", "-lc",
      'export PATH="$HOME/.moon/bin:$PATH"; exec moon "$@"', "moon", ...args], options)
    : spawnSync("moon", args, options);
  if (!distribution && result.error?.code === "ENOENT") {
    const exe = process.platform === "win32" ? "moon.exe" : "moon";
    result = spawnSync(join(homedir(), ".moon", "bin", exe), args, options);
  }
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error("MoonBit exited with status " + result.status);
}

const tempRoot = realpathSync(tmpdir());
const prefix = "moon-json-repair-readme-";
const scratch = mkdtempSync(join(tempRoot, prefix));
try {
  const library = join(scratch, "library");
  const consumer = join(scratch, "consumer");
  mkdirSync(library);
  mkdirSync(consumer);
  for (const entry of readdirSync(librarySource, { withFileTypes: true })) {
    if (!entry.isFile()) continue;
    const isSource = entry.name.endsWith(".mbt") && !entry.name.endsWith("_test.mbt");
    if (isSource || ["moon.mod", "moon.pkg", "README.md"].includes(entry.name)) {
      copyFileSync(join(librarySource, entry.name), join(library, entry.name));
    }
  }
  writeFileSync(join(scratch, "moon.work"), 'members = ["library", "consumer"]\n');
  writeFileSync(
    join(consumer, "moon.mod"),
    'name = "local/readme_consumer"\nimport {\n  "' + moduleName + "@" + version + '"\n}\n',
  );
  writeFileSync(join(consumer, "moon.pkg"), manifests[0] + "\n");
  writeFileSync(join(consumer, "readme_test.mbt"), examples.join("\n\n") + "\n");

  runMoon(["check", "--deny-warn", "--target", target, "--package-path", "consumer"], scratch);
  runMoon(["test", "--deny-warn", "--target", target, "--package", "local/readme_consumer"], scratch);
  console.log("Compiled README.md's import block and " + examples.length + " API examples as a separate " + target + " consumer.");
} finally {
  const created = realpathSync(scratch);
  if (dirname(created) !== tempRoot || !basename(created).startsWith(prefix)) {
    throw new Error("Unexpected README verification directory.");
  }
  rmSync(created, { recursive: true, force: true });
}
