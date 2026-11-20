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
  await wait("#stream-boundary", "Stream sealed");
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
  await blocks.nth(1).click();
  await outputHas("9007199254740993");
  await blocks.nth(2).click();
  await outputHas("send_notice");
  await page.locator("#enable-extraction").uncheck();
  await wait("#repair-state", "Unable to repair");
  await page.locator("#enable-extraction").check();
  await wait("#blocks", "Block 3");

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

  await page.locator("#benchmark").click();
  await wait("#bench-state", "10,000 attempts per engine");
  assert.equal(await page.locator("#bench-repair").textContent(), "100%");
  assert.equal(await page.locator("#bench-strict").textContent(), "0%");
  assert.match(await page.locator("#bench-repair-detail").textContent(), /\d+\.\d+ µs median · \d+\.\d+ MB\/s/);
  assert.equal(await page.locator("#bench-progress").evaluate(bar => bar.value), 10_000);

  if (process.argv.includes("--screenshot")) {
    await sample("Precision & coercion");
    await outputHas("9007199254740993");
    await page.locator("#stream").click();
    await wait("#stream-count", "Finalized");
    await wait("#schema-state", "Pass");
    await hex.click();
    await page.evaluate(() => window.scrollTo(0, 0));
    const benchBounds = await page.locator(".benchmark").boundingBox();
    assert.ok(benchBounds.y + benchBounds.height <= 1080, "Benchmark must remain inside the capture.");
    const png = await page.screenshot({ path: resolve(root, "screenshot.png"), animations: "disabled" });
    assert.equal(png.readUInt32BE(16), 1920);
    assert.equal(png.readUInt32BE(20), 1080);
  }

  const expectedAssets = ["", "style.css", "engine.js", "examples.js", "json-view.js", "app.js"];
  for (const asset of expectedAssets) assert.ok(paths.has(subpath + asset), "Missing " + asset);
  assert.deepEqual(errors, []);
  const narrow = await context.newPage();
  narrow.on("pageerror", error => errors.push(error.message));
  narrow.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  await narrow.setViewportSize({ width: 390, height: 844 });
  await narrow.goto(site);
  await narrow.waitForFunction(() => document.getElementById("schema-state").textContent === "Pass");
  assert.ok(await narrow.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));

  const offline = await browser.newContext({ offline: true });
  const filePage = await offline.newPage();
  filePage.on("pageerror", error => errors.push(error.message));
  filePage.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  await filePage.goto(pathToFileURL(resolve(root, "index.html")).href);
  await filePage.waitForFunction(() => document.getElementById("schema-state").textContent === "Pass");
  assert.deepEqual(errors, []);

  console.log("Subpath: " + site + " · 6 local assets · 0 HTTP errors and 0 console errors");
  console.log("Stream replay, pause, step, finalize, stack, and schema state changes verified.");
  console.log("Three extracted calls, JSON5, schema coercion, exact dual highlights, and retry prompt copy verified.");
  console.log("Lossless report retained the exact literal 9007199254740993 and was invalidated on empty input.");
  console.log("10,000 attempts per engine: " + await page.locator("#bench-repair").textContent() + " recovery vs " + await page.locator("#bench-strict").textContent() + " strict. " + await page.locator("#bench-repair-detail").textContent());
  console.log("390px viewport and offline file:// loading verified.");
} finally {
  if (browser) await browser.close();
  await new Promise(done => server.close(done));
}
