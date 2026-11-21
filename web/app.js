"use strict";

const elements = Object.fromEntries([
  "samples", "sample-description", "capability-engine", "stream", "stream-label", "step", "replay", "speed", "stream-count",
  "stream-progress", "stream-stack", "stream-boundary", "source", "source-gutter",
  "source-marking", "source-meta", "source-state", "enable-json5", "enable-coercion",
  "enable-extraction", "enable-ignore-think", "block-picker", "blocks", "output", "output-wrap",
  "result-gutter", "repair-state", "elapsed", "copy", "copy-label", "download",
  "audit-count", "audit-empty", "audit", "schema-state", "schema-summary",
  "schema-errors", "schema", "retry-card", "retry-prompt", "copy-retry", "benchmark",
  "bench-progress", "bench-state", "bench-repair", "bench-repair-detail", "bench-strict",
  "bench-strict-detail",
  "engine", "engine-wasm-option", "engine-status", "output-label", "trace-tab", "result-panel",
  "trace-panel", "fields", "fields-empty", "patches", "patches-empty", "patch-count",
  "bench-wasm", "bench-wasm-detail", "bench-wasm-size", "bench-js-size", "bench-ratio",
  "enable-mcp", "schema-label", "schema-editor-label", "schema-input-label",
  "latency-run", "latency-chunk", "latency-incremental", "latency-reference", "latency-range",
  "latency-progress", "latency-state", "code-card", "moonbit-code", "cli-code", "copy-moonbit", "copy-cli",
  "enable-semantic", "enable-diagnostics", "diagnostic-card", "diagnostic-output", "duel-tab", "duel-panel",
].map((id) => [id, document.getElementById(id)]));

const samples = [...examples, ...labFixtures];
const sampleButtons = [];
let sampleChunkWidth = null;
let outputText = "";
let rawReport = "";
let rawRetryPrompt = "";
let pendingFrame = 0;
let playback = null;
let playbackFrame = 0;
let copyTimer = null;
let blockIndex = 0;
let auditIndex = -1;
let visualAudit = null;
let lastTraceBlock = null;
const traceHistory = new Map();

function bridge(api) {
  return {
    run: (...args) => api.moonLabRun(...args),
    runOptions: typeof api.moonLabRunWithOptions === "function"
      ? (...args) => api.moonLabRunWithOptions(...args) : null,
    start: (...args) => api.moonLabStreamStart(...args),
    push: (chunk) => api.moonLabStreamPush(chunk),
    view: (...args) => api.moonLabStreamView(...args),
    viewOptions: typeof api.moonLabStreamViewWithOptions === "function"
      ? (...args) => api.moonLabStreamViewWithOptions(...args) : null,
    repairOnly: (input) => api.moonLabRepairOnly(input),
    guardMcp: (...args) => api.moonLabGuardMcp(...args),
    benchStart: () => api.moonLabBenchStart(),
    benchStep: (chunk, reference) => api.moonLabBenchStep(chunk, reference),
    benchMatches: () => api.moonLabBenchMatches(),
    benchFinish: () => api.moonLabBenchFinish(),
  };
}

const jsEngine = bridge(globalThis);
let wasmEngine = null;
let activeEngine = jsEngine;
let wasmModule;

async function createWasmEngine() {
  if (!wasmModule) {
    const pack = globalThis.moonWasmBuild;
    if (!pack) throw new Error("Missing built engine");
    const bytes = Uint8Array.from(atob(pack.base64), (unit) => unit.charCodeAt(0));
    wasmModule = WebAssembly.compile(bytes, { builtins: ["js-string"], importedStringConstants: "_" });
  }
  const instance = await WebAssembly.instantiate(await wasmModule, {});
  const candidate = bridge(instance.exports);
  if (!candidate.repairOnly("{}")) throw new Error("Wasm repair probe failed");
  return candidate;
}

async function loadWasm() {
  const pack = globalThis.moonWasmBuild;
  if (pack) {
    for (const [id, size] of Object.entries(pack.sizes)) {
      const metric = elements["bench-" + id + "-size"];
      labSet(metric, "{0} KiB · {1} KiB gzip", (size.raw / 1024).toFixed(1), (size.gzip / 1024).toFixed(1));
      labBind(metric, () => labText("{0} raw bytes · {1} gzip -9 bytes", size.raw.toLocaleString(), size.gzip.toLocaleString()), "title");
    }
  }
  try {
    wasmEngine = await createWasmEngine();
    elements["engine-wasm-option"].disabled = false;
    labSet(elements["engine-status"], "MoonBit JS and Wasm GC available");
  } catch {
    labSet(elements["engine-status"], "Wasm GC unavailable in this browser. Using MoonBit JS.");
    labSet(elements["bench-wasm-detail"], "Unavailable in this browser");
  }
}

let wasmReady;
function showEngine() {
  const name = activeEngine === wasmEngine ? "Wasm GC" : "MoonBit JS";
  const version = globalThis.moonWasmBuild?.version;
  labSet(elements["capability-engine"], "Current engine · {0}", version ? name + " · v" + version : name);
}

function node(tag, className, content) {
  const element = document.createElement(tag);
  element.className = className;
  element.textContent = content;
  return element;
}

function localizedNode(tag, className, key) {
  const element = node(tag, className, "");
  labSet(element, key);
  return element;
}

function setGutter(gutter, text, scrollTop) {
  const lines = text.split("\n").length;
  gutter.textContent = Array.from({ length: lines }, (_, index) => index + 1).join("\n");
  gutter.scrollTop = scrollTop;
  return lines;
}

function repairOptions() {
  return [
    elements["enable-json5"].checked,
    elements["enable-coercion"].checked,
    elements["enable-extraction"].checked,
    elements["enable-ignore-think"].checked,
  ];
}

function invalidateDownload() {
  rawReport = "";
  elements.download.disabled = true;
}

function showOutput(value, state, elapsed = "") {
  const wrap = elements["output-wrap"];
  const output = elements.output;
  const valid = state === "success";
  if (valid) {
    labClear(output);
    output.replaceChildren(prettyView(value, visualAudit.edits[auditIndex]?.output));
  } else {
    labBind(output, () => labValue(value));
  }
  const nextText = valid ? output.textContent : "";
  if (nextText !== outputText) {
    clearTimeout(copyTimer);
    labSet(elements["copy-label"], "Copy JSON");
  }
  outputText = nextText;
  wrap.dataset.error = String(state === "failure");
  wrap.dataset.empty = String(state === "idle");
  setGutter(elements["result-gutter"], outputText, wrap.scrollTop);
  const chip = elements["repair-state"];
  chip.className = valid ? "good" : state === "failure" ? "bad" : "";
  labSet(chip, { success: "✓ Valid JSON", failure: "Unable to repair", idle: "Awaiting input" }[state]);
  elements.elapsed.textContent = elapsed;
  elements.copy.disabled = !valid;
}

function scrollToMarker(scroller, marker) {
  if (!marker) return;
  const bottom = scroller.getBoundingClientRect().bottom;
  const top = scroller.getBoundingClientRect().top;
  const right = scroller.getBoundingClientRect().right;
  const left = scroller.getBoundingClientRect().left;
  const area = marker.getBoundingClientRect();
  if (area.top < top || area.bottom > bottom) scroller.scrollTop += area.top - top - 19;
  if (area.left < left || area.right > right) scroller.scrollLeft += area.left - left - 14;
}

function syncSourceScroll() {
  const source = elements.source;
  const mirror = elements["source-marking"];
  elements["source-gutter"].scrollTop = source.scrollTop;
  mirror.scrollTop = source.scrollTop;
  mirror.scrollLeft = source.scrollLeft;
}

function paintSource(range, reveal) {
  const mirror = elements["source-marking"];
  const source = elements.source;
  if (!range) {
    mirror.replaceChildren();
    return;
  }
  mirror.replaceChildren(highlightText(source.value, 0, range, true));
  if (range.start === source.value.length && range.end === range.start) endAnchor(mirror);
  // Keep a terminal line visible in the mirror when the source ends in LF.
  if (source.value.endsWith("\n")) mirror.append(" ");
  syncSourceScroll();
  if (reveal) {
    source.setSelectionRange(range.start, range.end);
    scrollToMarker(mirror, mirror.querySelector(".diff, .diff-anchor"));
    source.scrollTop = mirror.scrollTop;
    source.scrollLeft = mirror.scrollLeft;
    syncSourceScroll();
  }
}

function focusAudit(index) {
  if (index < 0 || !visualAudit?.edits[index]) return;
  pausePlayback();
  auditIndex = index;
  const entry = visualAudit.edits[index];
  for (const [position, item] of Array.from(elements.audit.children).entries()) {
    item.firstElementChild.setAttribute("aria-pressed", String(position === index));
  }
  paintSource(entry.source, true);
  elements.output.replaceChildren(prettyView(visualAudit.output, entry.output));
  const wrap = elements["output-wrap"];
  scrollToMarker(wrap, elements.output.querySelector(".diff, .diff-anchor"));
  elements["result-gutter"].scrollTop = wrap.scrollTop;
}

function showAudit(edits, emptyText) {
  labSet(elements["audit-count"], edits.length === 1 ? "{0} edit" : "{0} edits", edits.length);
  elements["audit-empty"].hidden = edits.length > 0;
  labBind(elements["audit-empty"], () => labValue(emptyText));
  const rows = document.createDocumentFragment();
  for (const [index, edit] of edits.entries()) {
    const row = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.setAttribute("aria-pressed", String(index === auditIndex));
    const mark = node("span", "audit-mark", "↳");
    mark.setAttribute("aria-hidden", "true");
    button.dataset.kind = edit.kind;
    const description = node("span", "audit-action", "");
    const action = node("span", "", "");
    const kind = node("small", "audit-kind", "");
    const position = node("span", "audit-position", "");
    labBind(action, () => edit.isCoercion ? edit.label : labEngineMessage(edit.label, "Repair adjustment"));
    labBind(kind, () => labEngineMessage(edit.kind, "Repair adjustment"));
    if (edit.position) {
      labSet(position, "L{0}:C{1}", edit.position.line, edit.position.column);
    } else {
      labSet(position, "Schema");
    }
    description.append(action, kind);
    button.append(mark, position, description);
    button.addEventListener("click", () => focusAudit(index));
    row.append(button);
    rows.append(row);
  }
  elements.audit.replaceChildren(rows);
}

function showSchema(state, badge, summary, errors = [], retry = "") {
  const status = elements["schema-state"];
  status.dataset.state = state;
  labBind(status, () => labValue(badge));
  labBind(elements["schema-summary"], () => labValue(summary));
  const rows = document.createDocumentFragment();
  for (const { path, message, keyword } of errors) {
    const row = document.createElement("li");
    const explanation = node("span", "", "");
    labBind(explanation, () => labEngineMessage(message, "Constraint was not met."));
    row.append(node("code", "schema-path", path + "  ·  " + keyword), explanation);
    rows.append(row);
  }
  elements["schema-errors"].replaceChildren(rows);
  elements["retry-card"].hidden = !retry;
  rawRetryPrompt = retry;
  labBind(elements["retry-prompt"], () => labRetryPrompt(retry));
  labSet(elements["copy-retry"], "Copy prompt");
}

function showStreamStatus(status) {
  elements["stream-progress"].max = playback?.tokens.length || 1;
  elements["stream-progress"].value = playback?.next ?? 0;
  if (playback) {
    const label = playback.error ? "Stopped" : playback.done ? "Finalized" : playback.playing ? "Live" : "Paused";
    const { next, tokens } = playback;
    labBind(elements["stream-count"], () => labText("{0} · {1}/{2} tokens", labText(label), next, tokens.length));
  } else {
    labSet(elements["stream-count"], "Ready · simulated tokens");
  }
  const stack = elements["stream-stack"];
  labSet(stack, status?.quote ? "Depth {0} · stack {1} · quote {2}" : "Depth {0} · stack {1}",
    status?.depth ?? 0, status?.stack.join(" ") || "∅", status?.quote);
  labBind(stack, () => stack.textContent, "title");
  const boundary = elements["stream-boundary"];
  if (status?.finalized) labSet(boundary, "Input finalized");
  else if (status?.stable) labSet(boundary, "Stable prefix");
  else if (status?.stable_offset > 0) labSet(boundary, "Checkpoint @{0}", status.stable_offset);
  else labSet(boundary, "No checkpoint");
}

function selectionRows(result, source, elapsed) {
  const extracting = elements["enable-extraction"].checked;
  elements["block-picker"].hidden = !extracting;
  if (!extracting) return;
  const buttons = result.blocks.map((block, index) => {
    const button = node("button", "", "");
    labSet(button, "Block {0} · {1}% · L{2}–{3}", index + 1, block.confidence, block.start.line, block.end.line);
    button.type = "button";
    button.setAttribute("aria-pressed", String(index === blockIndex));
    button.addEventListener("click", () => {
      pausePlayback();
      const previous = blockIndex;
      const changed = index !== previous || auditIndex >= 0;
      blockIndex = index;
      auditIndex = -1;
      // If edits or playback already queued a new frame, let it select the
      // block from the new result instead of displaying this older snapshot.
      if (!changed || pendingFrame) return;
      elements.blocks.children[previous]?.setAttribute("aria-pressed", "false");
      button.setAttribute("aria-pressed", "true");
      showBlock(source, block, elapsed);
    });
    return button;
  });
  if (!buttons.length) buttons.push(localizedNode("span", "toolbar-label", "No candidate blocks"));
  elements.blocks.replaceChildren(...buttons);
}

function collectTrace(block) {
  if (!block.trace?.patches.length) return;
  const key = block.start.offset;
  const ledger = traceHistory.get(key) ?? { total: 0, entries: [] };
  const wire = jsonView(block.trace.patches_json);
  for (const [index, operation] of block.trace.patches.entries()) {
    const span = wire.pointers.get("/" + index + "/value");
    const raw = span ? wire.text.slice(span.start, Math.min(span.end, span.start + 120)) : "";
    const value = span && span.end - span.start > raw.length ? raw + "…" : raw;
    ledger.entries.push({ op: operation.op, path: operation.path, value });
    ledger.total++;
  }
  if (ledger.entries.length > 120) ledger.entries = ledger.entries.slice(-120);
  traceHistory.set(key, ledger);
}

function showTrace(block) {
  lastTraceBlock = block;
  if (elements["trace-panel"].hidden) return;
  const trace = block?.trace;
  const ledger = trace && traceHistory.get(block.start.offset);
  labSet(elements["patch-count"], ledger ? "{0} ops" : "", ledger?.total);
  elements["patches-empty"].hidden = Boolean(ledger?.entries.length);
  const operations = document.createDocumentFragment();
  for (const { op, path, value } of ledger?.entries ?? []) {
    const row = node("li", "patch-row", "");
    const label = { add: "+ add", replace: "~ replace", remove: "− remove" }[op];
    row.dataset.op = op;
    row.append(localizedNode("span", "patch-op", label),
      path ? node("code", "patch-path", path) : localizedNode("code", "patch-path", "(root)"));
    if (value) row.append(node("code", "patch-value", value));
    operations.append(row);
  }
  elements.patches.replaceChildren(operations);
  elements.patches.scrollTop = elements.patches.scrollHeight;
  const fields = document.createDocumentFragment();
  if (trace) {
    const model = jsonView(trace.json);
    const argumentPaths = trace.fields.some(({ pointer }) => pointer.startsWith("/args/"));
    for (const { pointer, sealed } of trace.fields) {
      const span = model.pointers.get(pointer);
      if (!span || !pointer || (argumentPaths && !pointer.startsWith("/args/"))) continue;
      const first = model.text[span.start];
      if ((first === "[" || first === "{") && span.end - span.start > 2) continue;
      const raw = model.text.slice(span.start, Math.min(span.end, span.start + 240));
      const row = node("li", "field-row", "");
      row.dataset.pointer = pointer;
      row.dataset.state = sealed ? "sealed" : "streaming";
      row.append(node("code", "field-name", pointer), localizedNode("span", "field-state", row.dataset.state),
        node("code", "field-value", raw + (raw.length < span.end - span.start ? "…" : "")));
      fields.append(row);
    }
  }
  elements["fields-empty"].hidden = fields.childElementCount > 0;
  elements.fields.replaceChildren(fields);
}

function showDiagnostic(content) {
  elements["diagnostic-card"].hidden = !content;
  elements["diagnostic-output"].textContent = content ?? "";
}

function showBlock(source, block, elapsed) {
  showDiagnostic(block.diagnostic);
  showTrace(block);
  visualAudit = makeVisualAudit(source, block);
  if (auditIndex >= visualAudit.edits.length) auditIndex = -1;
  showOutput(visualAudit.output, "success", elapsed);
  showAudit(visualAudit.edits, "The input was already valid JSON.");
  paintSource(visualAudit.edits[auditIndex]?.source);
  const validation = block.validation;
  if (validation.state === "skipped") {
    showSchema("idle", "Skipped", "Add a schema to validate this block.");
  } else if (validation.state === "invalid_json") {
    showSchema("fail", "Invalid schema", () => labEngineMessage(validation.message, "Invalid schema"));
  } else if (validation.errors.length) {
    const count = validation.errors.length;
    showSchema("fail", "Fail", () => labText(count === 1 ? "{0} constraint error" : "{0} constraint errors", count), validation.errors, block.retry_prompt);
  } else {
    showSchema("pass", "Pass", block.coercions.length
      ? () => labText("Validated after {0} schema coercion edits.", block.coercions.length)
      : "The repaired value satisfies the current schema.");
  }
}

function renderMcp(source, registry, [json5, coerce, , ignoreThink]) {
  showTrace(null);
  paintSource(null);
  showStreamStatus(null);
  elements["block-picker"].hidden = true;
  visualAudit = null;
  if (!source.trim()) {
    showOutput("Enter a JSON-RPC frame to inspect.", "idle");
    showAudit([], "Repair counts will appear after the guard runs.");
    showSchema("idle", "Pending", "Provide a tool schema registry for tools/call.");
    return;
  }
  const started = performance.now();
  const result = JSON.parse(activeEngine.guardMcp(source, registry, json5, coerce, ignoreThink));
  const elapsed = (performance.now() - started).toFixed(2) + " ms";
  if (result.registry_error) {
    const registryError = () => labEngineMessage(result.registry_error, "Invalid registry");
    showOutput(registryError, "failure", elapsed);
    showAudit([], "The guard requires a valid tool schema registry.");
    showSchema("fail", "Invalid registry", registryError);
    return;
  }
  if (result.frame) {
    const displayFrame = result.forward ? result.frame : labMcpFrame(result.frame);
    visualAudit = { output: jsonView(displayFrame), edits: [] };
    showOutput(visualAudit.output, "success", elapsed);
    rawReport = result.frame;
    elements.download.disabled = false;
  } else {
    showOutput("No response frame. A rejected notification has no request ID.", "failure", elapsed);
  }
  const { envelope_edits, argument_edits, coercions } = result.audit;
  const audit = () => labText("{0} envelope edits · {1} argument edits · {2} coercions", envelope_edits, argument_edits, coercions);
  showAudit([], audit);
  if (result.forward) {
    showSchema("pass", "Forwarded", result.tool ? () => result.tool + " · " + audit() : "JSON-RPC frame passed through.");
  } else {
    const details = result.frame ? JSON.parse(result.frame).error?.data : null;
    showSchema("fail", () => labText("Blocked {0}", result.error_code), "The guard withheld this request.",
      details?.issues ?? [], details?.retry_prompt ?? "");
  }
}

function showProtectedInput(error) {
  invalidateDownload();
  visualAudit = null;
  paintSource(null);
  showStreamStatus(null);
  showTrace(null);
  selectionRows({ blocks: [] });
  const key = browserLimitMessages[error.kind] ?? "The engine could not display this input. Select a preset or edit the input.";
  showOutput(() => JSON.stringify({ error: { ...error, message: labText(key, error.limit) } }, null, 2), "failure");
  showAudit([], error.kind === "display_error" ? "No repair report is available for this input." : "The engine was not called for this input.");
  showSchema("idle", "Budget protection", "Shorten the input or select a preset to continue.");
}

function playbackBudget(current, schema) {
  if (current.checkedSchema !== schema) {
    current.checkedSchema = schema;
    current.budget = inspectLabInput(current.target, schema);
  }
  return current.budget;
}

function render() {
  const source = elements.source.value;
  const schemaText = elements.schema.value;
  showDiagnostic();
  const budget = playback ? playbackBudget(playback, schemaText) : inspectLabInput(source, schemaText);
  if (budget) {
    elements.source.dataset.inputError = budget.kind;
    elements.source.setAttribute("aria-invalid", "true");
    pausePlayback("Input held by browser limits");
  } else {
    const wasBlocked = Boolean(elements.source.dataset.inputError);
    delete elements.source.dataset.inputError;
    elements.source.removeAttribute("aria-invalid");
    if (wasBlocked) labSet(elements["source-state"], playback ? "Stream paused" : "Editable input");
  }
  const lines = setGutter(elements["source-gutter"], budget ? "" : source, elements.source.scrollTop);
  labSet(elements["source-meta"], lines === 1 ? "{0} line · {1} UTF-16 units" : "{0} lines · {1} UTF-16 units",
    budget ? "—" : lines, source.length);
  const hasInput = Boolean(source || playback?.tokens.length);
  const mcp = elements["enable-mcp"].checked;
  elements.stream.disabled = Boolean(budget) || mcp || !hasInput || Boolean(playback?.error);
  elements.step.disabled = Boolean(budget) || mcp || !hasInput || Boolean(playback?.done || playback?.error);
  elements.replay.disabled = Boolean(budget) || mcp || !hasInput;
  elements["enable-extraction"].disabled = mcp;
  elements["enable-semantic"].disabled = mcp;
  elements["enable-diagnostics"].disabled = mcp;
  elements["trace-tab"].disabled = mcp;
  labSet(elements["output-label"], mcp ? "JSON-RPC frame" : "Repaired JSON");
  labSet(elements["schema-label"], mcp ? "MCP guard decision" : "Schema validation");
  labSet(elements["schema-editor-label"], mcp ? "Edit tool schema registry" : "Edit schema");
  labSet(elements["schema-input-label"], mcp ? "Tool schema registry" : "JSON Schema");
  labBind(elements.schema, () => mcp ? '{"tool_name": {"type": "object"}}' : labText("Leave blank to skip validation"), "placeholder");
  if (budget) {
    labSet(elements["source-state"], "Input held by browser limits");
    selectOutputTab(false);
    showProtectedInput(budget);
    return;
  }

  if (typeof globalThis.moonLabRun !== "function") {
    visualAudit = null;
    showOutput("Cannot load the MoonBit engine. Rebuild it with node web/build.mjs.", "failure");
    showAudit([], "Repair output will appear after the engine loads.");
    showSchema("idle", "Pending", "Load the engine to run validation.");
    elements.benchmark.disabled = true;
    elements["latency-run"].disabled = true;
    return;
  }

  const schema = schemaText.trim();
  const options = repairOptions();
  if (mcp) {
    renderMcp(source, schema, options);
    return;
  }
  const started = performance.now();
  const semantic = elements["enable-semantic"].checked && options[1];
  const diagnostics = elements["enable-diagnostics"].checked;
  const enhanced = semantic || diagnostics;
  const extras = [semantic, diagnostics, labLanguage === "zh"];
  const raw = playback
    ? (enhanced && activeEngine.viewOptions
        ? activeEngine.viewOptions(source, schema, options[1], options[2], playback.done, ...extras)
        : activeEngine.view(source, schema, options[1], options[2], playback.done))
    : (enhanced && activeEngine.runOptions
        ? activeEngine.runOptions(source, schema, ...options, ...extras)
        : activeEngine.run(source, schema, ...options));
  const result = JSON.parse(raw); // Only for display. The original string is retained for download.
  const elapsed = (performance.now() - started).toFixed(2) + " ms";
  showStreamStatus(result.stream);
  visualAudit = null;
  if (!source.trim()) {
    showTrace(null);
    selectionRows({ blocks: [] });
    showOutput("Repaired JSON will appear here.", "idle");
    showAudit([], "Enter tool-call output to see the edits.");
    showSchema("idle", "Pending", "Validation runs as soon as repaired JSON is available.");
    paintSource(null);
    return;
  }
  if (!result.ok) {
    showDiagnostic(result.diagnostic);
    showTrace(null);
    selectionRows({ blocks: [] });
    const error = result.error;
    showOutput(() => labEngineMessage(error.message, "Unable to repair") + "\n\n" +
      labText("{0} · line {1}, column {2}", labEngineMessage(error.kind, "Unable to repair"),
        error.position.line, error.position.column), "failure", elapsed);
    showAudit([], "The engine is waiting for a repairable prefix or valid input.");
    showSchema("idle", "Pending", "Validation needs a repaired JSON value.");
    paintSource(null);
    return;
  }
  blockIndex = Math.min(blockIndex, Math.max(0, result.blocks.length - 1));
  for (const candidate of result.blocks) collectTrace(candidate);
  selectionRows(result, source, elapsed);
  const block = result.blocks[blockIndex];
  if (!block) {
    showTrace(null);
    showOutput("No complete or repairable candidate blocks found.", "idle", elapsed);
    showAudit([], "Paste a response containing a JSON object, array, or fenced block.");
    showSchema("idle", "Pending", "Select an extracted candidate to validate.");
    paintSource(null);
    return;
  }
  rawReport = raw;
  elements.download.disabled = false;
  showBlock(source, block, elapsed);
}

function scheduleRender() {
  invalidateDownload();
  if (!pendingFrame) pendingFrame = requestAnimationFrame(() => {
    pendingFrame = 0;
    try {
      render();
    } catch {
      showProtectedInput({ kind: "display_error" });
    }
  });
}

function resetPlayback() {
  cancelAnimationFrame(playbackFrame);
  playbackFrame = 0;
  playback = null;
  traceHistory.clear();
  elements.stream.dataset.running = "false";
  labSet(elements["stream-label"], "Simulate LLM stream");
  labSet(elements["source-state"], "Editable input");
}

function pausePlayback(message = "Stream paused") {
  if (!playback?.playing) return;
  cancelAnimationFrame(playbackFrame);
  playbackFrame = 0;
  playback.playing = false;
  elements.stream.dataset.running = "false";
  labSet(elements["stream-label"], playback.done ? "Simulate LLM stream" : "Resume stream");
  labSet(elements["source-state"], message);
  scheduleRender();
}

function startLabSession() {
  traceHistory.clear();
  activeEngine.start(
    elements["enable-json5"].checked,
    elements["enable-ignore-think"].checked,
  );
}

function startPlayback(target) {
  resetPlayback();
  const checkedSchema = elements.schema.value;
  if (!target || inspectLabInput(target, checkedSchema)) return;
  // Small groups of Unicode code points and delimiters model delta.arguments
  // chunks without pretending to use any provider's specific tokenizer.
  const tokens = sampleChunkWidth
    ? Array.from({ length: Math.ceil(target.length / sampleChunkWidth) },
      (_, index) => target.slice(index * sampleChunkWidth, (index + 1) * sampleChunkWidth))
    : target.match(/[\p{L}\p{N}_]{1,5}|[ \t]{1,4}|\r\n|[\s\S]/gu) ?? [];
  playback = { tokens, target, checkedSchema, budget: null, next: 0, done: false, playing: false, error: false, clock: 0, balance: 0 };
  startLabSession();
  elements.source.value = "";
  blockIndex = 0;
  auditIndex = -1;
  labSet(elements["source-state"], "Stream ready");
  scheduleRender();
}

function pushTokens(count) {
  const current = playback;
  if (!current || current.done || current.error) return;
  const next = Math.min(current.next + count, current.tokens.length);
  const chunk = current.tokens.slice(current.next, next).join("");
  if (!activeEngine.push(chunk)) {
    current.error = true;
    pausePlayback("Stream input limit reached");
    labSet(elements["source-state"], "Stream input limit reached");
    scheduleRender();
    return;
  }
  elements.source.value += chunk;
  elements.source.scrollTop = elements.source.scrollHeight;
  current.next = next;
  auditIndex = -1;
  if (current.next === current.tokens.length) {
    current.done = true;
    pausePlayback("Stream complete");
    labSet(elements["stream-label"], "Simulate LLM stream");
    labSet(elements["source-state"], "Stream complete");
  }
  scheduleRender();
}

function animateStream(time) {
  const current = playback;
  if (!current?.playing) return;
  if (!current.clock) current.clock = time;
  const elapsed = Math.min(100, time - current.clock);
  current.clock = time;
  current.balance += elapsed * Number(elements.speed.value) / 1000;
  const count = Math.floor(current.balance);
  if (count) {
    current.balance -= count;
    pushTokens(count);
  }
  if (current.playing) playbackFrame = requestAnimationFrame(animateStream);
}

function play() {
  if (playback?.playing) {
    pausePlayback();
    return;
  }
  if (!playback || playback.done || playback.error) startPlayback(playback?.target ?? elements.source.value);
  if (!playback) return;
  if (playbackBudget(playback, elements.schema.value)) return;
  playback.clock = 0;
  playback.playing = true;
  elements.stream.dataset.running = "true";
  labSet(elements["stream-label"], "Pause stream");
  labSet(elements["source-state"], "Receiving tokens…");
  playbackFrame = requestAnimationFrame(animateStream);
  scheduleRender();
}

function loadSample(index) {
  const { input, schema, modes = {}, transport } = samples[index];
  resetPlayback();
  sampleButtons.forEach((button, buttonIndex) => {
    button.setAttribute("aria-pressed", String(buttonIndex === index));
  });
  labSet(elements["sample-description"], samples[index].description);
  elements.source.value = input;
  elements.schema.value = schema ? JSON.stringify(schema, null, 2) : "";
  elements["enable-json5"].checked = Boolean(modes.json5);
  elements["enable-coercion"].checked = Boolean(modes.coerce);
  elements["enable-semantic"].checked = Boolean(modes.semantic);
  elements["enable-diagnostics"].checked = Boolean(modes.diagnostics);
  elements["enable-extraction"].checked = Boolean(modes.extract);
  elements["enable-ignore-think"].checked = Boolean(modes.ignoreThink);
  elements["enable-mcp"].checked = Boolean(modes.mcp);
  sampleChunkWidth = transport ?? null;
  if (modes.duel) {
    document.getElementById("duel-fixture").value = modes.duel;
    selectOutputTab("duel");
    void runDuel();
  } else if (modes.mcp || !elements["duel-panel"].hidden) {
    selectOutputTab(false);
  }
  elements.source.scrollTop = 0;
  elements["output-wrap"].scrollTop = 0;
  blockIndex = 0;
  auditIndex = -1;
  scheduleRender();
  refreshCodeSnippets();
}

async function copyText(text, fallback) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const range = document.createRange();
    const selection = window.getSelection();
    range.selectNodeContents(fallback);
    selection.removeAllRanges();
    selection.addRange(range);
    const copyOriginal = event => {
      if (!event.clipboardData) return;
      event.preventDefault();
      event.clipboardData.setData("text/plain", text);
    };
    document.addEventListener("copy", copyOriginal);
    let copied;
    try {
      copied = document.execCommand("copy");
    } finally {
      document.removeEventListener("copy", copyOriginal);
    }
    if (copied) selection.removeAllRanges();
    return copied;
  }
}

function overlaps(range, start, end) {
  return range && (range.start === range.end ? start <= range.start && range.start < end
    : range.start < end && range.end > start);
}

const sampleGroups = new Map();
for (const [id, label] of [["stream", "Stream triage"], ["mcp", "MCP firewall"],
  ["latency", "50 KB incremental benchmark"], ["precision", "Precision and coercion"]]) {
  const item = node("div", "sample-group", "");
  item.id = "sample-" + id;
  const heading = localizedNode("span", "toolbar-label", label);
  heading.id = item.id + "-label";
  const buttons = node("div", "sample-list", "");
  buttons.setAttribute("role", "group");
  buttons.setAttribute("aria-labelledby", heading.id);
  item.append(heading, buttons);
  elements.samples.append(item);
  sampleGroups.set(id, buttons);
}
for (const [index, sample] of samples.entries()) {
  const button = localizedNode("button", "", sample.label);
  button.type = "button";
  labBind(button, () => labText(sample.description), "title");
  button.addEventListener("click", () => loadSample(index));
  sampleGroups.get(sample.group).append(button);
  sampleButtons.push(button);
}

elements.source.addEventListener("input", () => {
  resetPlayback();
  sampleChunkWidth = null;
  for (const button of sampleButtons) button.setAttribute("aria-pressed", "false");
  labSet(elements["sample-description"], "");
  blockIndex = 0;
  auditIndex = -1;
  scheduleRender();
  refreshCodeSnippets();
});
elements.schema.addEventListener("input", () => {
  auditIndex = -1;
  scheduleRender();
  refreshCodeSnippets();
});
elements.engine.addEventListener("change", () => {
  activeEngine = elements.engine.value === "wasm" && wasmEngine ? wasmEngine : jsEngine;
  showEngine();
  if (playback) {
    startLabSession();
    activeEngine.push(elements.source.value);
  }
  scheduleRender();
});

const outputTabs = [["output-label", "result"], ["trace-tab", "trace"], ["duel-tab", "duel"]];

function selectOutputTab(tab) {
  const selected = typeof tab === "boolean" ? (tab ? "trace" : "result") : tab;
  if (selected === "trace" && elements["enable-mcp"].checked) return;
  for (const [id, name] of outputTabs) {
    const active = selected === name;
    elements[id].setAttribute("aria-selected", String(active));
    elements[id].tabIndex = active ? 0 : -1;
  }
  for (const [, name] of outputTabs) elements[name + "-panel"].hidden = selected !== name;
  if (selected === "trace") showTrace(lastTraceBlock);
}

for (const [id, name] of outputTabs) {
  const tab = elements[id];
  tab.addEventListener("click", () => selectOutputTab(name));
  tab.addEventListener("keydown", (event) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const available = outputTabs.filter(([candidate]) => !elements[candidate].disabled);
    const current = available.findIndex(([candidate]) => candidate === id);
    const last = available.length - 1;
    const next = event.key === "Home" ? 0 : event.key === "End" ? last
      : (current + (event.key === "ArrowRight" ? 1 : last)) % available.length;
    selectOutputTab(available[next][1]);
    elements[available[next][0]].focus();
  });
}
for (const id of ["enable-json5", "enable-coercion", "enable-extraction", "enable-ignore-think", "enable-mcp",
  "enable-semantic", "enable-diagnostics"]) {
  elements[id].addEventListener("change", () => {
    if (id === "enable-semantic" && elements[id].checked) elements["enable-coercion"].checked = true;
    if (id === "enable-coercion" && !elements[id].checked) elements["enable-semantic"].checked = false;
    if (id === "enable-mcp" && elements[id].checked) {
      resetPlayback();
      selectOutputTab(false);
    }
    if (playback && ["enable-json5", "enable-ignore-think"].includes(id)) {
      startLabSession();
      activeEngine.push(elements.source.value);
    }
    auditIndex = -1;
    blockIndex = 0;
    scheduleRender();
    refreshCodeSnippets();
  });
}
elements.source.addEventListener("scroll", syncSourceScroll);
elements["output-wrap"].addEventListener("scroll", () => {
  elements["result-gutter"].scrollTop = elements["output-wrap"].scrollTop;
});
elements.source.addEventListener("pointerup", () => {
  const start = elements.source.selectionStart;
  const end = Math.max(start + 1, elements.source.selectionEnd);
  focusAudit(visualAudit?.edits.findIndex(entry => overlaps(entry.source, start, end)) ?? -1);
});
elements.output.addEventListener("click", (event) => {
  const token = event.target.closest("[data-start]");
  if (!token) return;
  const start = Number(token.dataset.start);
  const end = Number(token.dataset.end);
  focusAudit(visualAudit?.edits.findIndex(entry => overlaps(entry.output, start, end)) ?? -1);
});
elements.stream.addEventListener("click", play);
elements.step.addEventListener("click", () => {
  pausePlayback();
  if (!playback) startPlayback(elements.source.value);
  if (playback && playbackBudget(playback, elements.schema.value)) return;
  pushTokens(1);
});
elements.replay.addEventListener("click", () => {
  startPlayback(playback?.target ?? elements.source.value);
  play();
});
elements.copy.addEventListener("click", async () => {
  const text = elements["enable-mcp"].checked ? rawReport : outputText;
  const copied = await copyText(text, elements.output);
  labSet(elements["copy-label"], copied ? "Copied" : "Text selected");
  clearTimeout(copyTimer);
  copyTimer = setTimeout(() => { labSet(elements["copy-label"], "Copy JSON"); }, 1400);
});
elements["copy-retry"].addEventListener("click", async () => {
  const copied = await copyText(rawRetryPrompt, elements["retry-prompt"]);
  labSet(elements["copy-retry"], copied ? "Copied" : "Text selected");
});
elements.download.addEventListener("click", () => {
  if (!rawReport) return;
  const url = URL.createObjectURL(new Blob([rawReport], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = "moon-json-repair-report.json";
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 500);
});

const nextFrame = () => new Promise(requestAnimationFrame);

function benchBatch(run, input, count) {
  let success = 0;
  const start = performance.now();
  for (let i = 0; i < count; i++) if (run(input)) success++;
  return { success, ms: performance.now() - start };
}

function showBenchmarkBatch(lane, count, inputBytes) {
  const values = lane.results.slice().sort((left, right) => left - right);
  const middle = Math.floor(values.length / 2);
  const median = values.length % 2 === 0 ? (values[middle - 1] + values[middle]) / 2 : values[middle];
  lane.median = median;
  const throughput = lane.ms > 0 ? (count * inputBytes / (lane.ms * 1000)).toFixed(2) + " MB/s" : null;
  elements[lane.id].textContent = (lane.success / count * 100).toFixed(0) + "%";
  labBind(elements[lane.id + "-detail"], () => labText("{0} µs median · {1}",
    median.toFixed(2), throughput ?? labText("MB/s pending")));
}

elements.benchmark.addEventListener("click", async () => {
  elements.benchmark.disabled = true;
  labSet(elements["bench-state"], "Running on this device…");
  await wasmReady;
  const input = examples[0].input;
  const inputBytes = new TextEncoder().encode(input).length;
  const strict = (text) => {
    try { JSON.parse(text); return true; } catch { return false; }
  };
  const engines = [[jsEngine.repairOnly, "bench-repair"], [strict, "bench-strict"]];
  if (wasmEngine) engines.splice(1, 0, [wasmEngine.repairOnly, "bench-wasm"]);
  const lanes = engines.map(([run, id]) => ({ run, id, results: [], success: 0, ms: 0, median: 0 }));
  const total = 10_000;
  const batch = 250;
  elements["bench-progress"].value = 0;
  try {
    for (const lane of lanes) benchBatch(lane.run, input, batch);
    for (let count = batch; count <= total; count += batch) {
      const offset = (count / batch) % lanes.length;
      for (let index = 0; index < lanes.length; index++) {
        const lane = lanes[(index + offset) % lanes.length];
        const result = benchBatch(lane.run, input, batch);
        lane.results.push(result.ms * 1000 / batch);
        lane.ms += result.ms;
        lane.success += result.success;
        showBenchmarkBatch(lane, count, inputBytes);
      }
      elements["bench-progress"].value = count;
      await nextFrame();
    }
    if (wasmEngine && lanes[0].median > 0 && lanes[1].median > 0) {
      const ratio = lanes[0].median / lanes[1].median;
      labSet(elements["bench-ratio"], ratio >= 1 ? "{0}× Wasm GC / JS speed" : "{0}× JS / Wasm GC speed",
        (ratio >= 1 ? ratio : 1 / ratio).toFixed(2));
    }
    labSet(elements["bench-state"], "10,000 attempts per engine");
  } catch (error) {
    labBind(elements["bench-state"], () => labText("Benchmark failed: {0}", labEngineMessage(error.message, "Unable to repair")));
  } finally {
    elements.benchmark.disabled = false;
  }
});

initializeLabLanguage(() => {
  refreshCodeSnippets();
  showChaosDiagnostic();
  if (elements["enable-diagnostics"].checked || elements["enable-mcp"].checked) scheduleRender();
});
showEngine();
for (const item of elements.speed.options) labSet(item, "{0} tok/s", item.value);
for (const item of elements["latency-chunk"].options) labSet(item, "{0} units", item.value);
wasmReady = loadWasm();
connectLabTools();
connectArena();
loadSample(0);
