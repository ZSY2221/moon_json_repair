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
  const context = await browser.newContext({ viewport: { width: 1920, height: 1080 }, acceptDownloads: true, locale: "en-US" });
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
  for (const entry of ["moonLabRun", "moonLabStreamStart", "moonLabStreamPush", "moonLabStreamView", "moonLabRepairOnly",
    "moonLabRunWithOptions", "moonLabStreamViewWithOptions"]) {
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

  const reasoningPreset = "Reasoning draft + truncated calls";
  const thinkSwitch = page.locator("#enable-ignore-think");
  const ignoredThink = page.locator('#audit button[data-kind="ignore_think_block"]');
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

  const hex = page.locator('#audit button[data-kind="hex_int_to_decimal"]');
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
  await wait("#capability-engine", "Wasm GC");
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

  await sample("Semantic normalization");
  await wait("#output", "9007199254740993");
  await wait("#schema-state", "Pass");
  assert.match(await page.locator("#output").textContent(), /"user_name"\s*:\s*"Ada"/u);
  assert.match(await page.locator("#output").textContent(), /"currency"\s*:\s*"USD"/u);
  assert.ok(await page.locator("#enable-semantic").isChecked());
  await page.locator("#enable-semantic").uncheck();
  await wait("#schema-state", "Fail");
  await page.locator("#enable-semantic").check();
  await wait("#schema-state", "Pass");
  await sample("Stream cut");
  if (!(await page.locator("#schema").isVisible())) await page.locator("#schema-editor-label").click();
  await page.locator("#schema").fill('{"type":"object","required":["user_name","currency","amount"],"properties":{"user_name":{"type":"string"},"currency":{"enum":["USD","EUR"]},"amount":{"type":"integer"}}}');
  await page.locator("#source").fill('{"userName":"Ada","currency":" usd ","amount":"9007199254740993"}');
  await page.locator("#enable-coercion").check();
  await page.locator("#enable-semantic").check();
  await page.locator("#enable-diagnostics").check();
  await wait("#output", "9007199254740993");
  await wait("#schema-state", "Pass");
  assert.match(await page.locator("#output").textContent(), /"user_name"\s*:\s*"Ada"/u);
  assert.match(await page.locator("#output").textContent(), /"currency"\s*:\s*"USD"/u);
  const semanticDownloadPending = page.waitForEvent("download");
  await page.locator("#download").click();
  const semanticDownload = await semanticDownloadPending;
  assert.match(await readFile(await semanticDownload.path(), "utf8"), /"amount":9007199254740993/u);
  await page.locator("#source").fill('{\n  "user_name": "星球🌙",\n  "currency": "USD",\n  "amount": "wrong"\n}');
  await wait("#schema-state", "Fail");
  await page.locator("#diagnostic-card > summary").click();
  await wait("#diagnostic-output", "error[type]");
  assert.match(await page.locator("#diagnostic-output").textContent(), /1\s*\|[^\n]*"amount":"wrong"/u);
  assert.match(await page.locator("#diagnostic-output").textContent(), /\^{5,}/u);
  await page.locator("#lang-zh").click();
  await wait("#diagnostic-output", "错误[type]");
  assert.match(await page.locator("#diagnostic-output").textContent(), /\$\.amount/u);
  await page.locator("#lang-en").click();
  await wait("#diagnostic-output", "error[type]");

  await page.evaluate(() => {
    window.duelFrames = [];
    const strict = document.getElementById("duel-strict-status");
    const fields = document.getElementById("duel-arguments");
    const counter = document.getElementById("duel-patch-count");
    const source = document.getElementById("duel-input");
    const watch = new MutationObserver(() => {
      window.duelFrames.push({
        strict: strict.dataset.state,
        sealed: fields.querySelectorAll('[data-sealed="true"]').length,
        patches: Number(counter.dataset.count),
        raw: source.textContent,
        visible: fields.textContent,
      });
    });
    watch.observe(document.getElementById("duel-panel"), { childList: true, subtree: true, attributes: true });
  });
  await sample("Travel booking duel");
  assert.equal(await page.locator("#duel-tab").getAttribute("aria-selected"), "true");
  await page.waitForFunction(() => document.getElementById("duel-progress").dataset.state === "complete", null, { timeout: 45_000 });
  assert.equal(await page.locator("#duel-strict-status").getAttribute("data-state"), "ready");
  const duelFrames = await page.evaluate(() => window.duelFrames);
  assert.ok(duelFrames.some(frame => frame.raw.includes("Draft only") && !frame.raw.includes("</think>") && frame.patches === 0));
  assert.ok(duelFrames.every(frame => !frame.visible.includes("Draft only")), "The draft must never appear in a business card");
  assert.match(await page.locator("#duel-input").textContent(), /^<think>\n.*\n<\/think>\n\{"tool":"plan_trip"/u);
  assert.ok(duelFrames.some(frame => frame.strict === "waiting" && frame.sealed > 0 && frame.patches > 0),
    "Wasm must show actual sealed arguments and patches while JSON.parse still awaits complete input");
  assert.ok(Number(await page.locator("#duel-patch-count").getAttribute("data-count")) > 0);
  assert.match(await page.locator("#duel-field-lag").textContent(), /\d[\d.,]*\s*(?:ms|µs)/u);
  assert.match(await page.locator("#duel-engine-time").textContent(), /\d[\d.,]*\s*(?:ms|µs)/u);

  await page.locator("#chaos-run").click();
  await page.waitForFunction(() => document.getElementById("chaos-status").dataset.state === "complete", null, { timeout: 60_000 });
  const arenaCounts = {};
  for (const name of ["processed", "repaired", "refused", "panics"]) {
    arenaCounts[name] = Number((await page.locator("#chaos-" + name).textContent()).replace(/\D/g, ""));
  }
  assert.equal(arenaCounts.processed, 1_152);
  assert.equal(arenaCounts.repaired + arenaCounts.refused, arenaCounts.processed);
  assert.ok(arenaCounts.repaired > 0 && arenaCounts.refused > 0);
  assert.equal(arenaCounts.panics, 0);
  assert.match(await page.locator("#chaos-throughput").textContent(), /[1-9]/u);

  const expectedAssets = ["", "style.css", "engine.js", "engine-wasm.js", "i18n.js", "examples.js", "json-view.js", "lab-tools.js", "arena.js", "app.js"];
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

  const offline = await browser.newContext({ offline: true, locale: "en-US" });
  const filePage = await offline.newPage();
  filePage.on("pageerror", error => errors.push(error.message));
  filePage.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  await filePage.goto(pathToFileURL(resolve(root, "index.html")).href);
  await filePage.waitForFunction(() => document.getElementById("schema-state").textContent === "Pass");
  await filePage.waitForFunction(() => !document.getElementById("engine-wasm-option").disabled);
  await filePage.locator("#engine").selectOption("wasm");
  await filePage.getByRole("button", { name: "Patch stream", exact: true }).click();
  await filePage.waitForFunction(() => document.getElementById("output").textContent.includes("9007199254740993"));
  await filePage.locator("#lang-zh").click();
  assert.equal(await filePage.locator("html").getAttribute("lang"), "zh-CN");
  assert.match(await filePage.locator("#output-label").textContent(), /\p{Script=Han}/u);
  assert.match(await filePage.locator("#output").textContent(), /9007199254740993/);
  await filePage.locator("#duel-tab").click();
  await filePage.locator("#duel-run").click();
  await filePage.waitForFunction(() => document.getElementById("duel-progress").dataset.state === "complete", null, { timeout: 45_000 });
  const fallback = await context.newPage();
  fallback.on("pageerror", error => errors.push(error.message));
  fallback.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  await fallback.addInitScript(() => { WebAssembly.instantiate = async () => { throw new Error("unsupported test host"); }; });
  await fallback.goto(site);
  await fallback.waitForFunction(() => document.getElementById("engine-status").textContent.includes("Wasm GC unavailable"));
  assert.equal(await fallback.locator("#engine-wasm-option").isDisabled(), true);
  await fallback.waitForFunction(() => document.getElementById("schema-state").textContent === "Pass");

  const localizedContext = await browser.newContext({ locale: "zh-TW", viewport: { width: 390, height: 844 }, acceptDownloads: true });
  await localizedContext.grantPermissions(["clipboard-read", "clipboard-write"]);
  const localized = await localizedContext.newPage();
  localized.on("pageerror", error => errors.push(error.message));
  localized.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  localized.on("requestfailed", request => errors.push("Language test request failed: " + request.url()));
  localized.on("response", response => {
    if (response.status() >= 400) errors.push("Language test HTTP " + response.status() + ": " + response.url());
    if (!response.url().startsWith(site)) errors.push("Language test external request: " + response.url());
  });
  await localized.goto(site);
  const checkLanguage = async (language, locale) => {
    await localized.waitForFunction(expected => document.documentElement.lang === expected, locale);
    assert.equal(await localized.locator("#lang-" + language).getAttribute("aria-pressed"), "true");
    const selectors = [
      "#stream-label", "#source-label", "#output-label", "#trace-tab", "#audit-label",
      "#fields-label", "#step", "#replay", "#benchmark", "#latency-run",
      "#copy-moonbit", "#copy-cli", "#capability-engine", "#sample-stream-label",
      "#sample-mcp-label", "#sample-latency-label", "#sample-precision-label", "#duel-tab",
      "#duel-run", "#chaos-heading", "#chaos-run", "#diagnostic-card > summary",
    ];
    const labels = await localized.locator(selectors.join(",")).allTextContents();
    assert.equal(labels.length, selectors.length);
    for (const label of labels) {
      assert.ok(label.trim(), "An interactive label must be present");
      assert.equal(/\p{Script=Han}/u.test(label), language === "zh", "Unexpected language: " + label);
    }
  };
  await checkLanguage("zh", "zh-CN");
  await localized.locator("#source").fill('{"value":"🌙","id":9007199254740993}');
  await localized.waitForFunction(() => document.getElementById("output").textContent.includes("9007199254740993"));
  await localized.locator("#enable-ignore-think").check();
  await localized.evaluate(() => { window.languageContinuityProbe = true; });
  const beforeLanguage = await localized.locator("#source").inputValue();
  await localized.locator("#lang-en").click();
  await checkLanguage("en", "en");
  assert.equal(await localized.evaluate(() => window.languageContinuityProbe), true, "Language switching reloaded the document");
  assert.equal(await localized.locator("#source").inputValue(), beforeLanguage);
  assert.ok(await localized.locator("#enable-ignore-think").isChecked());
  assert.match(await localized.locator("#output").textContent(), /9007199254740993/);
  await localized.goto(site);
  await checkLanguage("en", "en");
  assert.equal(await localized.evaluate(() => localStorage.getItem("moon-json-repair-lang")), "en");
  await localized.goto(site + "?lang=zh");
  await checkLanguage("zh", "zh-CN");
  assert.ok(await localized.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
  await localized.getByRole("button", { name: "MCP 参数拦截", exact: true }).click();
  await localized.waitForFunction(() => document.getElementById("output").textContent.includes("-32602"));
  assert.match(await localized.locator("#schema-state").textContent(), /[\u3400-\u9fff].*-32602/);
  const preview = await localized.locator("#output").textContent();
  assert.match(preview, /"id"\s*:\s*9007199254740993/);
  const previewError = JSON.parse(preview).error;
  assert.equal(previewError.message, "参数无效");
  assert.ok(previewError.data.issues.every(({ message }) => /\p{Script=Han}/u.test(message)));
  assert.doesNotMatch(previewError.data.retry_prompt, /expected string|Unicode code points/u);
  const downloadedFrame = localized.waitForEvent("download");
  await localized.locator("#download").click();
  const originalFrame = await readFile(await (await downloadedFrame).path(), "utf8");
  assert.match(originalFrame, /"id":9007199254740993(?=[,}])/u);
  assert.equal(JSON.parse(originalFrame).error.message, "Invalid params");
  await localized.locator("#copy").click();
  await localized.waitForFunction(() => document.getElementById("copy-label").textContent === "已复制");
  assert.equal(await localized.evaluate(() => navigator.clipboard.readText()), originalFrame);
  await localized.locator("#lang-en").click();
  await localized.waitForFunction(() => document.getElementById("output").textContent.includes("Invalid params"));
  await localized.locator("#lang-zh").click();
  await localized.waitForFunction(() => document.getElementById("output").textContent.includes("参数无效"));
  await localized.locator("#code-card > summary").click();
  assert.match(await localized.locator("#cli-code").textContent(), /#[^\n]*[\u3400-\u9fff]/);
  await localized.goto(site + "?lang=en");
  await checkLanguage("en", "en");

  await localized.locator("#engine").selectOption("js");
  await localized.waitForFunction(() => document.getElementById("schema-state").textContent === "Pass");
  await localized.evaluate(() => {
    window.guardEngineCalls = 0;
    for (const name of ["moonLabRun", "moonLabRunWithOptions"]) {
      const run = window[name];
      window[name] = (...args) => {
        window.guardEngineCalls++;
        return run(...args);
      };
    }
  });
  for (const [kind, source] of [
    ["input_limit", "?".repeat(500_000)],
    ["depth_limit", "[".repeat(1_000) + "]".repeat(1_000)],
    ["escape_limit", '{"value":"' + "\\q".repeat(17_000) + '"}'],
  ]) {
    await localized.locator("#source").fill(source);
    await localized.waitForFunction(
      expected => document.getElementById("source").dataset.inputError === expected, kind, { timeout: 5_000 },
    );
    const protectedOutput = JSON.parse(await localized.locator("#output").textContent());
    assert.equal(protectedOutput.error.kind, kind);
    assert.equal(await localized.locator("#source").getAttribute("aria-invalid"), "true");
    assert.ok((await localized.locator("#repair-state").textContent()).trim());
    assert.ok(await localized.locator("#download").isDisabled());
    assert.ok(await localized.locator("#benchmark").isEnabled());
    assert.ok(await localized.locator("#latency-run").isEnabled());
  }
  assert.equal(await localized.evaluate(() => window.guardEngineCalls), 0, "Rejected input reached the JS engine");
  await localized.locator("#lang-zh").click();
  await checkLanguage("zh", "zh-CN");
  assert.equal(new URL(localized.url()).searchParams.get("lang"), "zh");
  const chineseGuard = JSON.parse(await localized.locator("#output").textContent());
  assert.equal(chineseGuard.error.kind, "escape_limit", "Language switching changed the input guard");
  assert.match(chineseGuard.error.message, /\p{Script=Han}/u);
  await localized.locator("#lang-en").click();
  await checkLanguage("en", "en");
  await localized.locator("#source").fill("");
  await localized.waitForFunction(() => document.getElementById("repair-state").textContent.includes("Awaiting input"));
  await localized.locator("#source").fill("🌙🧪🚀");
  await localized.waitForFunction(() => document.getElementById("repair-state").textContent.includes("Unable to repair"));
  assert.ok(await localized.locator("#download").isDisabled());
  await localized.getByRole("button", { name: "Stream cut", exact: true }).click();
  await localized.waitForFunction(() => document.getElementById("output").textContent.includes("Investigate checkout timeout"));
  assert.ok(await localized.locator("#download").isEnabled());
  assert.notEqual(await localized.locator("#source").getAttribute("aria-invalid"), "true");
  await localizedContext.close();
  assert.deepEqual(errors, []);

  console.log("Edge/Chromium " + browser.version() + " at " + site + " · " + expectedAssets.length + " local assets · 0 HTTP errors and 0 console errors");
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
  console.log("Live UI Duel rendered sealed fields ahead of strict JSON.parse, with measured Patch and timing counters.");
  console.log("Chaos Arena · " + arenaCounts.processed + " cases · " + arenaCounts.repaired + " repairs · " + arenaCounts.refused + " refusals · " + arenaCounts.panics + " failures");
  console.log("Semantic coercion, localized compiler-style carets and exact wide integer download verified.");
  console.log("Chinese/English default and overrides, in-place switching, preference memory, and 390px layout verified.");
  console.log("Offline file:// bilingual Wasm GC and JS fallback verified.");
  console.log("500 KiB input, 1,000 nesting levels, malformed escapes, empty input, emoji, and post-rejection recovery verified.");
} finally {
  if (browser) await browser.close();
  await new Promise(done => server.close(done));
}
