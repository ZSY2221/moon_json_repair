import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { extname, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const root = fileURLToPath(new URL("../web/", import.meta.url));
const subpath = "/moon_json_repair/";
const types = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".png": "image/png",
};

const server = createServer(async (request, response) => {
  const pathname = new URL(request.url, "http://127.0.0.1").pathname;
  if (!pathname.startsWith(subpath)) {
    response.writeHead(404).end();
    return;
  }
  const file = resolve(root, pathname.slice(subpath.length) || "index.html");
  if (!file.startsWith(resolve(root) + sep) || !types[extname(file)]) {
    response.writeHead(404).end();
    return;
  }
  try {
    const body = await readFile(file);
    response.writeHead(200, { "content-type": types[extname(file)] }).end(body);
  } catch {
    response.writeHead(404).end();
  }
});

await new Promise((done, reject) => server.listen(0, "127.0.0.1", done).once("error", reject));
const site = "http://127.0.0.1:" + server.address().port + subpath;
let browser;
try {
  let executablePath = process.env.PLAYWRIGHT_BROWSER;
  if (!executablePath && process.platform === "win32") {
    const edge = "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe";
    try { await access(edge); executablePath = edge; } catch { /* Use bundled Chromium. */ }
  }
  browser = await chromium.launch({ executablePath, headless: true });
  const context = await browser.newContext({ viewport: { width: 1920, height: 1080 }, acceptDownloads: true });
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  const page = await context.newPage();
  const errors = [];
  const paths = new Set();
  page.on("pageerror", error => errors.push(error.message));
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  page.on("requestfailed", request => errors.push("Failed request: " + request.url()));
  page.on("response", response => {
    if (response.status() >= 400) errors.push("HTTP " + response.status() + ": " + response.url());
    if (!response.url().startsWith(site)) errors.push("External request: " + response.url());
    paths.add(new URL(response.url()).pathname);
  });
  await page.goto(site);
  const wait = (selector, value) => page.waitForFunction(
    ({ selector, value }) => document.querySelector(selector).textContent.includes(value), { selector, value },
  );
  const sample = label => page.getByRole("button", { name: label, exact: true }).click();
  // Wait for both text and status to avoid reading a previous animation frame.
  const outputHas = async fragment => {
    await wait("#output", fragment);
    await wait("#repair-state", "Valid JSON");
    return JSON.parse(await page.locator("#output").textContent());
  };

  await outputHas("Investigate checkout timeout");
  await wait("#schema-state", "Pass");
  await wait("#engine-status", "and Wasm GC available");
  assert.equal(await page.locator("#engine-wasm-option").isDisabled(), false);
  const wasmAbi = await page.evaluate(async () => {
    const bytes = Uint8Array.from(atob(window.moonWasmBuild.base64), unit => unit.charCodeAt(0));
    const module = await WebAssembly.compile(bytes, { builtins: ["js-string"], importedStringConstants: "_" });
    return { magic: Array.from(bytes.slice(0, 4)), imports: WebAssembly.Module.imports(module),
      exports: WebAssembly.Module.exports(module).map(({ name }) => name) };
  });
  assert.deepEqual(wasmAbi.magic, [0, 97, 115, 109]);
  assert.deepEqual(wasmAbi.imports, []);
  for (const entry of ["moonLabRun", "moonLabStreamStart", "moonLabStreamPush", "moonLabStreamView", "moonLabRepairOnly"]) {
    assert.ok(wasmAbi.exports.includes(entry), "Missing Wasm GC function " + entry);
  }
  assert.equal(await page.locator("#enable-ignore-think").isChecked(), false);
  const initial = await page.locator("#source").inputValue();
  await page.evaluate(() => {
    globalThis.schemaStates = [];
    new MutationObserver(() => {
      globalThis.schemaStates.push(document.getElementById("schema-state").textContent);
    }).observe(document.getElementById("schema-state"), { childList: true });
  });
  await page.locator("#speed").selectOption("30");
  await page.locator("#stream").click();
  await page.waitForFunction(() => /^Live · [1-9]/.test(document.getElementById("stream-count").textContent));
  await page.locator("#stream").click();
  await wait("#stream-count", "Paused");
  const paused = await page.locator("#source").inputValue();
  assert.ok(paused.length > 0 && paused.length < initial.length);
  await page.locator("#step").click();
  assert.ok((await page.locator("#source").inputValue()).length > paused.length);
  await page.locator("#speed").selectOption("120");
  await page.locator("#stream").click();
  await wait("#stream-count", "Finalized");
  await wait("#stream-boundary", "Input finalized");
  await wait("#stream-stack", "Depth 2");
  await wait("#schema-state", "Pass");
  assert.equal(await page.locator("#source").inputValue(), initial);
  assert.ok((await page.evaluate(() => globalThis.schemaStates)).includes("Fail"), "Partial schema states should be visible");
  await page.locator("#replay").click();
  await wait("#stream-count", "Live");

  await sample("Multiple calls");
  await outputHas("search_docs");
  const blocks = page.locator("#blocks button");
  assert.equal(await blocks.count(), 3);
  assert.match(await blocks.nth(0).textContent(), /Block 1 · \d+% · L\d/);
  await page.evaluate(() => {
    window.engineRunsForBlockSwitch = 0;
    const run = window.moonLabRun;
    window.moonLabRun = (...args) => {
      window.engineRunsForBlockSwitch++;
      return run(...args);
    };
  });
  await blocks.nth(1).click();
  await outputHas("9007199254740993");
  await blocks.nth(2).click();
  await outputHas("send_notice");
  assert.equal(await page.evaluate(() => window.engineRunsForBlockSwitch), 0, "Switching an extracted block should reuse the rendered result");
  await page.locator("#enable-extraction").uncheck();
  await wait("#repair-state", "Unable to repair");
  await page.locator("#enable-extraction").check();
  await wait("#blocks", "Block 3");

  const reasoningPreset = "推理草稿 + 截断调用";
  const thinkSwitch = page.locator("#enable-ignore-think");
  const ignoredThink = page.locator("#audit button").filter({ hasText: "ignore_think_block" });
  await sample(reasoningPreset);
  const exactBody = await outputHas("9007199254740993");
  await wait("#schema-state", "Pass");
  assert.equal(exactBody.args.note, "Literal <think>marker</think>");
  assert.equal(await thinkSwitch.isChecked(), true);
  assert.equal(await blocks.count(), 2);
  assert.equal(await ignoredThink.count(), 1);
  const modelSource = await page.locator("#source").inputValue();
  const reasoningEnd = modelSource.indexOf("</tHiNk>") + "</tHiNk>".length;
  const reasoning = modelSource.slice(0, reasoningEnd);
  assert.equal(await page.evaluate(source => (
    window.moonLabRun(source, "", false, false, true) ===
    window.moonLabRun(source, "", false, false, true, false)
  ), modelSource), true, "Omitting the new browser flag preserves the previous entry point");
  await ignoredThink.click();
  assert.equal(await page.locator("#source-marking mark").textContent(), reasoning);
  assert.equal(await page.locator("#output mark, #output .diff-anchor").count(), 0);
  await blocks.nth(1).click();
  await outputHas("Status 🌙");
  await blocks.nth(0).click();
  await outputHas("9007199254740993");
  await page.locator("#source").evaluate(input => {
    input.setSelectionRange(1, 2);
    input.dispatchEvent(new PointerEvent("pointerup"));
  });
  assert.equal(await ignoredThink.getAttribute("aria-pressed"), "true");
  assert.equal(await page.locator("#source-marking mark").textContent(), reasoning);

  const thoughtDownloadEvent = page.waitForEvent("download");
  await page.locator("#download").click();
  const thoughtDownload = await thoughtDownloadEvent;
  const thoughtRaw = await readFile(await thoughtDownload.path(), "utf8");
  assert.match(thoughtRaw, /"account":9007199254740993(?=[,}])/);
  assert.match(thoughtRaw, /"kind":"ignore_think_block"/);
  assert.doesNotMatch(thoughtRaw, /draft_guess/);

  await thinkSwitch.uncheck();
  await outputHas("draft_guess");
  await wait("#schema-state", "Fail");
  assert.equal(await blocks.count(), 3);
  await thinkSwitch.check();
  await outputHas("9007199254740993");
  await wait("#schema-state", "Pass");
  assert.equal(await blocks.count(), 2);
  await page.locator("#source").fill(reasoning.slice(0, -"</tHiNk>".length));
  await wait("#blocks", "No candidate blocks");
  assert.equal(await page.locator("#download").isDisabled(), true);

  await sample(reasoningPreset);
  await outputHas("9007199254740993");
  await page.locator("#speed").selectOption("30");
  await page.locator("#stream").click();
  await page.waitForFunction(() => {
    const prefix = document.getElementById("source").value;
    return prefix.includes('"draft_guess"') && !prefix.includes("</tHiNk>");
  });
  await page.locator("#stream").click();
  await wait("#blocks", "No candidate blocks");
  await page.locator("#speed").selectOption("120");
  await page.locator("#stream").click();
  await wait("#stream-count", "Finalized");
  await outputHas("9007199254740993");
  assert.equal(await blocks.count(), 2);

  await page.locator("#source").fill(modelSource.split("\n\n")[0]);
  await page.locator("#enable-extraction").uncheck();
  await outputHas("9007199254740993");
  await ignoredThink.click();
  assert.equal(await page.locator("#source-marking mark").textContent(), reasoning);

  await sample("Precision & coercion");
  await outputHas("9007199254740993");
  await wait("#schema-state", "Pass");
  await page.locator("#enable-json5").uncheck();
  await wait("#repair-state", "Unable to repair");
  await page.locator("#enable-json5").check();
  await outputHas("9007199254740993");
  await page.locator("#enable-coercion").uncheck();
  await wait("#schema-state", "Fail");
  await page.locator("#enable-coercion").check();
  const healed = await outputHas("9007199254740993");
  await wait("#schema-state", "Pass");
  assert.equal(healed.args.amount, 42.5);
  assert.equal(healed.args.approved, true);
  assert.deepEqual(healed.args.tags, ["invoice"]);

  const hex = page.locator("#audit button").filter({ hasText: "hex_int_to_decimal" });
  await hex.click();
  assert.equal(await page.locator("#source-marking mark").textContent(), "0x20000000000001");
  assert.equal(await page.locator("#output mark").textContent(), "9007199254740993");
  const coercion = page.locator("#audit button").filter({ hasText: "$.args.amount" });
  await coercion.click();
  assert.equal(await page.locator("#source-marking mark").textContent(), '"42.5"');
  assert.equal(await page.locator("#output mark").textContent(), "42.5");
  await page.locator("#output .token-number").filter({ hasText: "9007199254740993" }).click();
  assert.equal(await hex.getAttribute("aria-pressed"), "true");

  const downloadEvent = page.waitForEvent("download");
  await page.locator("#download").click();
  const download = await downloadEvent;
  assert.equal(download.suggestedFilename(), "moon-json-repair-report.json");
  const raw = await readFile(await download.path(), "utf8");
  assert.match(raw, /"request_id":9007199254740993(?=[,}])/);
  assert.doesNotMatch(raw, /"request_id":9007199254740992(?=[,}])/);
  assert.match(raw, /"coercions":\[/);
  await page.locator("#source").fill("");
  await wait("#repair-state", "Awaiting input");
  assert.equal(await page.locator("#download").isDisabled(), true);

  await sample("Schema rejection");
  await wait("#schema-state", "Fail");
  await wait("#retry-prompt", "$.args.amount");
  await wait("#retry-prompt", "$.args.currency");
  await wait("#retry-prompt", "$.args.tags[1]");
  await page.locator("#copy-retry").click();
  await wait("#copy-retry", "Copied");
  const clipboard = await page.evaluate(() => navigator.clipboard.readText());
  assert.equal(clipboard.replace(/\r\n/g, "\n"), await page.locator("#retry-prompt").textContent());

  const jsRuns = await page.evaluate(() => window.engineRunsForBlockSwitch);
  await page.locator("#engine").selectOption("wasm");
  await sample("Patch stream");
  await outputHas("9007199254740993");
  await wait("#schema-state", "Pass");
  assert.equal(await page.evaluate(() => window.engineRunsForBlockSwitch), jsRuns, "Wasm selection must avoid the JS backend");
  await page.getByRole("tab", { name: "Live patches" }).click();
  await page.evaluate(() => {
    window.fieldSealHistory = [];
    const fields = document.getElementById("fields");
    new MutationObserver(() => {
      const line = fields.querySelector('[data-pointer="/args/line~0item"]');
      if (line) window.fieldSealHistory.push(line.dataset.state);
    }).observe(fields, { childList: true });
  });
  await page.locator("#speed").selectOption("60");
  await page.locator("#stream").click();
  await wait("#stream-count", "Finalized");
  await wait("#schema-state", "Pass");
  assert.equal(await page.locator('#fields [data-pointer="/args/order~1id"]').getAttribute("data-state"), "sealed");
  assert.equal(await page.locator('#fields [data-pointer="/args/order~1id"] .field-value').textContent(), "9007199254740993");
  assert.equal(await page.locator('#fields [data-pointer="/args/memo"]').getAttribute("data-state"), "streaming");
  const fieldStates = await page.evaluate(() => window.fieldSealHistory);
  assert.ok(fieldStates.includes("streaming") && fieldStates.at(-1) === "sealed", "A completed string must change from streaming to sealed");
  const patchText = await page.locator("#patches").textContent();
  assert.match(patchText, /\+ add\/args\/line~0item/);
  assert.match(patchText, /~ replace\/args\/memo/);
  assert.match(patchText, /9007199254740993/);
  assert.doesNotMatch(patchText, /9007199254740992|scratch/);

  const wasmDownloadEvent = page.waitForEvent("download");
  await page.locator("#download").click();
  const wasmDownload = await wasmDownloadEvent;
  const wasmReport = await readFile(await wasmDownload.path(), "utf8");
  assert.match(wasmReport, /"order\/id":9007199254740993(?=[,}])/);
  assert.match(wasmReport, /"trace":\{/);
  assert.doesNotMatch(wasmReport, /9007199254740992|scratch/);
  await page.getByRole("tab", { name: "Live patches" }).press("ArrowLeft");
  assert.equal(await page.getByRole("tab", { name: "Repaired JSON" }).getAttribute("aria-selected"), "true");
  await outputHas("9007199254740993");

  await page.locator("#benchmark").click();
  await wait("#bench-state", "10,000 attempts per engine");
  assert.equal(await page.locator("#bench-repair").textContent(), "100%");
  assert.equal(await page.locator("#bench-wasm").textContent(), "100%");
  assert.equal(await page.locator("#bench-strict").textContent(), "0%");
  assert.match(await page.locator("#bench-repair-detail").textContent(), /\d+\.\d+ µs median · \d+\.\d+ MB\/s/);
  assert.match(await page.locator("#bench-wasm-detail").textContent(), /\d+\.\d+ µs median · \d+\.\d+ MB\/s/);
  assert.match(await page.locator("#bench-ratio").textContent(), /\d+\.\d+×/);
  assert.match(await page.locator("#bench-wasm-size").textContent(), /KiB gzip/);
  assert.equal(await page.locator("#bench-progress").evaluate(bar => bar.value), 10_000);

  await sample("50 KB write_file");
  const generated = await outputHas("generated.js");
  assert.equal(Buffer.byteLength(generated.args.content), 50_000);
  await page.locator("#latency-run").click();
  await wait("#latency-state", "snapshots matched");
  assert.match(await page.locator("#latency-state").textContent(), /^Wasm GC · \d+ snapshots matched/);
  for (const lane of ["incremental", "reference"]) {
    assert.ok((await page.locator("#latency-" + lane).getAttribute("points")).split(" ").length > 190);
  }
  const streamLatency = await page.locator("#latency-state").textContent();

  if (process.argv.includes("--screenshot")) {
    await sample("Patch stream");
    await outputHas("9007199254740993");
    await ignoredThink.click();
    await page.getByRole("tab", { name: "Live patches" }).click();
    await page.locator("#stream").click();
    await wait("#stream-count", "Finalized");
    await page.locator(".latency-card").evaluate(panel => {
      const bottom = panel.getBoundingClientRect().bottom + window.scrollY;
      window.scrollTo(0, Math.max(0, bottom - window.innerHeight + 12));
    });
    const chartBounds = await page.locator(".latency-card").boundingBox();
    assert.ok(chartBounds.y + chartBounds.height <= 1080, "Stream comparison must appear in the capture.");
    const png = await page.screenshot({ path: resolve(root, "screenshot.png"), animations: "disabled" });
    assert.equal(png.readUInt32BE(16), 1920);
    assert.equal(png.readUInt32BE(20), 1080);
  }

  await sample("MCP tools/call");
  await wait("#schema-state", "Forwarded");
  const forwarded = await outputHas("hello from MoonBit");
  assert.equal(forwarded.params.arguments.content, "hello from MoonBit");
  const guardDownloadEvent = page.waitForEvent("download");
  await page.locator("#download").click();
  const guardDownload = await guardDownloadEvent;
  assert.match(await readFile(await guardDownload.path(), "utf8"), /"id":9007199254740993/);
  await sample("MCP invalid params");
  const rejected = await outputHas("-32602");
  await wait("#schema-state", "Blocked -32602");
  assert.ok(rejected.error.data.issues.some(({ path }) => path.startsWith("$.params.arguments")));
  await page.getByText("Run this configuration locally", { exact: true }).click();
  await wait("#moonbit-code", "@repair.guard_mcp_tool_call");
  await wait("#cli-code", "--mcp-guard --tool-schemas $labSchema");
  await page.locator("#enable-ignore-think").check();
  await wait("#cli-code", "--ignore-think");
  await page.locator("#copy-cli").click();
  await wait("#copy-cli", "Copied");
  assert.equal((await page.evaluate(() => navigator.clipboard.readText())).replace(/\r\n/g, "\n"),
    await page.locator("#cli-code").textContent());

  const expectedAssets = ["", "style.css", "engine.js", "engine-wasm.js", "examples.js", "json-view.js", "lab-tools.js", "app.js"];
  for (const asset of expectedAssets) assert.ok(paths.has(subpath + asset), "Missing " + asset);
  assert.deepEqual(errors, []);
  const narrow = await context.newPage();
  narrow.on("pageerror", error => errors.push(error.message));
  narrow.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  await narrow.setViewportSize({ width: 390, height: 844 });
  await narrow.goto(site);
  await narrow.waitForFunction(() => document.getElementById("schema-state").textContent === "Pass");
  await narrow.getByRole("button", { name: "Patch stream", exact: true }).click();
  await narrow.getByRole("tab", { name: "Live patches" }).click();
  assert.ok(await narrow.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
  await narrow.getByRole("button", { name: "MCP tools/call", exact: true }).click();
  await narrow.getByText("Run this configuration locally", { exact: true }).click();
  assert.ok(await narrow.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));

  const offline = await browser.newContext({ offline: true });
  const filePage = await offline.newPage();
  filePage.on("pageerror", error => errors.push(error.message));
  filePage.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  await filePage.goto(pathToFileURL(resolve(root, "index.html")).href);
  await filePage.waitForFunction(() => document.getElementById("schema-state").textContent === "Pass");
  await filePage.waitForFunction(() => !document.getElementById("engine-wasm-option").disabled);
  await filePage.locator("#engine").selectOption("wasm");
  await filePage.getByRole("button", { name: "Patch stream", exact: true }).click();
  await filePage.waitForFunction(() => document.getElementById("output").textContent.includes("9007199254740993"));
  const fallback = await context.newPage();
  fallback.on("pageerror", error => errors.push(error.message));
  fallback.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  await fallback.addInitScript(() => { WebAssembly.instantiate = async () => { throw new Error("unsupported test host"); }; });
  await fallback.goto(site);
  await fallback.waitForFunction(() => document.getElementById("engine-status").textContent.includes("Wasm GC unavailable"));
  assert.equal(await fallback.locator("#engine-wasm-option").isDisabled(), true);
  await fallback.waitForFunction(() => document.getElementById("schema-state").textContent === "Pass");
  assert.deepEqual(errors, []);

  console.log("Edge/Chromium " + browser.version() + " at " + site + " · 8 local assets · 0 HTTP errors and 0 console errors");
  console.log("Stream replay, pause, step, finalize, stack, and schema state changes verified.");
  console.log("Three extracted calls, JSON5, schema coercion, exact dual highlights, and retry prompt copy verified.");
  console.log("Think mode: mixed-case tags, literal markers, open and streamed blocks, source projection, and exact download verified.");
  console.log("Lossless report retained the exact literal 9007199254740993 and was invalidated on empty input.");
  console.log("Live RFC 6902 operations, RFC 6901 paths, streaming-to-sealed fields, and Wasm GC exact raw download verified.");
  console.log("Edge instantiated the Wasm binary with JS string builtins and zero ordinary host imports.");
  for (const [label, id] of [["MoonBit JS", "repair"], ["MoonBit Wasm GC", "wasm"], ["JSON.parse", "strict"]]) {
    console.log(label + " · 10,000 attempts · " + await page.locator("#bench-" + id).textContent() + " · " + await page.locator("#bench-" + id + "-detail").textContent());
  }
  console.log(await page.locator("#bench-ratio").textContent());
  console.log(streamLatency);
  console.log("MCP tool forwarding, -32602, exact ID download, and clipboard code options verified.");
  console.log("390px viewport, offline file:// Wasm GC, and JS fallback verified.");
} finally {
  if (browser) await browser.close();
  await new Promise(done => server.close(done));
}
