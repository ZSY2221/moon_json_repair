"use strict";

const elements = Object.fromEntries([
  "samples", "stream", "stream-label", "step", "replay", "speed", "stream-count",
  "stream-progress", "stream-stack", "stream-boundary", "source", "source-gutter",
  "source-marking", "source-meta", "source-state", "enable-json5", "enable-coercion",
  "enable-extraction", "block-picker", "blocks", "output", "output-wrap",
  "result-gutter", "repair-state", "elapsed", "copy", "copy-label", "download",
  "audit-count", "audit-empty", "audit", "schema-state", "schema-summary",
  "schema-errors", "schema", "retry-card", "retry-prompt", "copy-retry", "benchmark",
  "bench-progress", "bench-state", "bench-repair", "bench-repair-detail", "bench-strict",
  "bench-strict-detail",
].map((id) => [id, document.getElementById(id)]));

const samples = [...examples, ...labFixtures];
let outputText = "";
let rawReport = "";
let pendingFrame = 0;
let playback = null;
let playbackFrame = 0;
let copyTimer = null;
let blockIndex = 0;
let auditIndex = -1;
let visualAudit = null;

function node(tag, className, content) {
  const element = document.createElement(tag);
  element.className = className;
  element.textContent = content;
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
  output.replaceChildren(valid ? prettyView(value, visualAudit.edits[auditIndex]?.output) : value);
  const nextText = valid ? output.textContent : "";
  if (nextText !== outputText) {
    clearTimeout(copyTimer);
    elements["copy-label"].textContent = "Copy JSON";
  }
  outputText = nextText;
  wrap.dataset.error = String(state === "failure");
  wrap.dataset.empty = String(state === "idle");
  setGutter(elements["result-gutter"], outputText, wrap.scrollTop);
  const chip = elements["repair-state"];
  chip.className = valid ? "good" : state === "failure" ? "bad" : "";
  chip.textContent = { success: "✓ Valid JSON", failure: "Unable to repair", idle: "Awaiting input" }[state];
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
  elements["audit-count"].textContent = edits.length + (edits.length === 1 ? " edit" : " edits");
  elements["audit-empty"].hidden = edits.length > 0;
  elements["audit-empty"].textContent = emptyText;
  const rows = document.createDocumentFragment();
  for (const [index, edit] of edits.entries()) {
    const row = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.setAttribute("aria-pressed", String(index === auditIndex));
    const mark = node("span", "audit-mark", "↳");
    mark.setAttribute("aria-hidden", "true");
    const description = node("span", "audit-action", edit.label);
    description.append(node("small", "audit-kind", edit.kind));
    button.append(mark, node("span", "audit-position", edit.location), description);
    button.addEventListener("click", () => focusAudit(index));
    row.append(button);
    rows.append(row);
  }
  elements.audit.replaceChildren(rows);
}

function showSchema(state, badge, summary, errors = [], retry = "") {
  const status = elements["schema-state"];
  status.dataset.state = state;
  status.textContent = badge;
  elements["schema-summary"].textContent = summary;
  const rows = document.createDocumentFragment();
  for (const { path, message, keyword } of errors) {
    const row = document.createElement("li");
    row.append(node("code", "schema-path", path + "  ·  " + keyword), node("span", "", message));
    rows.append(row);
  }
  elements["schema-errors"].replaceChildren(rows);
  elements["retry-card"].hidden = !retry;
  elements["retry-prompt"].textContent = retry;
  elements["copy-retry"].textContent = "Copy prompt";
}

function showStreamStatus(status) {
  elements["stream-progress"].max = playback?.tokens.length || 1;
  elements["stream-progress"].value = playback?.next ?? 0;
  let count = "Ready · simulated tokens";
  if (playback) {
    const label = playback.error ? "Stopped" : playback.done ? "Finalized" : playback.playing ? "Live" : "Paused";
    count = label + " · " + playback.next + "/" + playback.tokens.length + " tokens";
  }
  elements["stream-count"].textContent = count;
  const stack = elements["stream-stack"];
  stack.textContent = status
    ? "Depth " + status.depth + " · stack " + (status.stack.join(" ") || "∅") + (status.quote ? " · quote " + status.quote : "")
    : "Depth 0 · stack ∅";
  stack.title = stack.textContent;
  const boundary = elements["stream-boundary"];
  boundary.textContent = status?.finalized ? "Stream sealed"
    : status?.stable ? "Stable prefix"
    : status?.stable_offset > 0 ? "Checkpoint @" + status.stable_offset
    : "No checkpoint";
}

function selectionRows(result) {
  const extracting = elements["enable-extraction"].checked;
  elements["block-picker"].hidden = !extracting;
  if (!extracting) return;
  const buttons = result.blocks.map((block, index) => {
    const text = "Block " + (index + 1) + " · " + block.confidence + "% · L" + block.start.line + "–" + block.end.line;
    const button = node("button", "", text);
    button.type = "button";
    button.setAttribute("aria-pressed", String(index === blockIndex));
    button.addEventListener("click", () => {
      pausePlayback();
      blockIndex = index;
      auditIndex = -1;
      render();
      elements.blocks.children[index]?.focus();
    });
    return button;
  });
  if (!buttons.length) buttons.push(node("span", "toolbar-label", "No candidate blocks"));
  elements.blocks.replaceChildren(...buttons);
}

function render() {
  const source = elements.source.value;
  const lines = setGutter(elements["source-gutter"], source, elements.source.scrollTop);
  elements["source-meta"].textContent = lines + (lines === 1 ? " line" : " lines") + "  ·  " + source.length + " UTF-16 units";
  const hasInput = Boolean(source || playback?.tokens.length);
  elements.stream.disabled = !hasInput || Boolean(playback?.error);
  elements.step.disabled = !hasInput || Boolean(playback?.done || playback?.error);
  elements.replay.disabled = !hasInput;

  if (typeof globalThis.moonLabRun !== "function") {
    visualAudit = null;
    showOutput("Cannot load the MoonBit engine. Rebuild it with node web/build.mjs.", "failure");
    showAudit([], "Repair output will appear after the engine loads.");
    showSchema("idle", "Pending", "Load the engine to run validation.");
    elements.benchmark.disabled = true;
    return;
  }

  const schema = elements.schema.value.trim();
  const options = repairOptions();
  const started = performance.now();
  const raw = playback
    ? globalThis.moonLabStreamView(source, schema, options[1], options[2], playback.done)
    : globalThis.moonLabRun(source, schema, ...options);
  const result = JSON.parse(raw); // Only for display. The original string is retained for download.
  const elapsed = (performance.now() - started).toFixed(2) + " ms";
  showStreamStatus(result.stream);
  visualAudit = null;
  if (!source.trim()) {
    selectionRows({ blocks: [] });
    showOutput("Repaired JSON will appear here.", "idle");
    showAudit([], "Enter tool-call output to see the edits.");
    showSchema("idle", "Pending", "Validation runs as soon as repaired JSON is available.");
    paintSource(null);
    return;
  }
  if (!result.ok) {
    selectionRows({ blocks: [] });
    const error = result.error;
    showOutput(error.message + "\n\n" + error.kind + " · line " + error.position.line + ", column " + error.position.column, "failure", elapsed);
    showAudit([], "The engine is waiting for a repairable prefix or valid input.");
    showSchema("idle", "Pending", "Validation needs a repaired JSON value.");
    paintSource(null);
    return;
  }
  blockIndex = Math.min(blockIndex, Math.max(0, result.blocks.length - 1));
  selectionRows(result);
  const block = result.blocks[blockIndex];
  if (!block) {
    showOutput("No complete or repairable candidate blocks found.", "idle", elapsed);
    showAudit([], "Paste a response containing a JSON object, array, or fenced block.");
    showSchema("idle", "Pending", "Select an extracted candidate to validate.");
    paintSource(null);
    return;
  }
  rawReport = raw;
  elements.download.disabled = false;
  visualAudit = makeVisualAudit(source, block);
  if (auditIndex >= visualAudit.edits.length) auditIndex = -1;
  showOutput(visualAudit.output, "success", elapsed);
  showAudit(visualAudit.edits, "The input was already valid JSON.");
  paintSource(visualAudit.edits[auditIndex]?.source);
  const validation = block.validation;
  if (validation.state === "skipped") {
    showSchema("idle", "Skipped", "Add a schema to validate this block.");
  } else if (validation.state === "invalid_json") {
    showSchema("fail", "Invalid schema", validation.message);
  } else if (validation.errors.length) {
    const count = validation.errors.length;
    showSchema("fail", "Fail", count + (count === 1 ? " constraint error" : " constraint errors"), validation.errors, block.retry_prompt);
  } else {
    showSchema("pass", "Pass", block.coercions.length
      ? "Validated after " + block.coercions.length + " schema coercion edits."
      : "The repaired value satisfies the current schema.");
  }
}

function scheduleRender() {
  invalidateDownload();
  if (!pendingFrame) pendingFrame = requestAnimationFrame(() => {
    pendingFrame = 0;
    render();
  });
}

function resetPlayback() {
  cancelAnimationFrame(playbackFrame);
  playbackFrame = 0;
  playback = null;
  elements.stream.dataset.running = "false";
  elements["stream-label"].textContent = "模拟 LLM 实时流式输出";
  elements["source-state"].textContent = "Editable input";
}

function pausePlayback(message = "Stream paused") {
  if (!playback?.playing) return;
  cancelAnimationFrame(playbackFrame);
  playbackFrame = 0;
  playback.playing = false;
  elements.stream.dataset.running = "false";
  elements["stream-label"].textContent = playback.done ? "模拟 LLM 实时流式输出" : "Resume stream";
  elements["source-state"].textContent = message;
  scheduleRender();
}

function startPlayback(target) {
  resetPlayback();
  if (!target) return;
  // Small groups of Unicode code points and delimiters model delta.arguments
  // chunks without pretending to use any provider's specific tokenizer.
  const tokens = target.match(/[\p{L}\p{N}_]{1,5}|[ \t]{1,4}|\r\n|[\s\S]/gu) ?? [];
  playback = { tokens, target, next: 0, done: false, playing: false, error: false, clock: 0, balance: 0 };
  globalThis.moonLabStreamStart(elements["enable-json5"].checked);
  elements.source.value = "";
  blockIndex = 0;
  auditIndex = -1;
  elements["source-state"].textContent = "Stream ready";
  scheduleRender();
}

function pushTokens(count) {
  const current = playback;
  if (!current || current.done || current.error) return;
  const next = Math.min(current.next + count, current.tokens.length);
  const chunk = current.tokens.slice(current.next, next).join("");
  if (!globalThis.moonLabStreamPush(chunk)) {
    current.error = true;
    pausePlayback("Stream input limit reached");
    elements["source-state"].textContent = "Stream input limit reached";
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
    elements["stream-label"].textContent = "模拟 LLM 实时流式输出";
    elements["source-state"].textContent = "Stream complete";
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
  playback.clock = 0;
  playback.playing = true;
  elements.stream.dataset.running = "true";
  elements["stream-label"].textContent = "Pause stream";
  elements["source-state"].textContent = "Receiving tokens…";
  playbackFrame = requestAnimationFrame(animateStream);
  scheduleRender();
}

function loadSample(index) {
  const { input, schema, modes = {} } = samples[index];
  resetPlayback();
  Array.from(elements.samples.children).forEach((button, buttonIndex) => {
    button.setAttribute("aria-pressed", String(buttonIndex === index));
  });
  elements.source.value = input;
  elements.schema.value = schema ? JSON.stringify(schema, null, 2) : "";
  elements["enable-json5"].checked = Boolean(modes.json5);
  elements["enable-coercion"].checked = Boolean(modes.coerce);
  elements["enable-extraction"].checked = Boolean(modes.extract);
  elements.source.scrollTop = 0;
  elements["output-wrap"].scrollTop = 0;
  blockIndex = 0;
  auditIndex = -1;
  scheduleRender();
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
    const copied = document.execCommand("copy");
    if (copied) selection.removeAllRanges();
    return copied;
  }
}

function overlaps(range, start, end) {
  return range && (range.start === range.end ? start <= range.start && range.start < end
    : range.start < end && range.end > start);
}

for (const [index, sample] of samples.entries()) {
  const button = node("button", "", sample.label);
  button.type = "button";
  button.addEventListener("click", () => loadSample(index));
  elements.samples.append(button);
}

elements.source.addEventListener("input", () => {
  resetPlayback();
  for (const button of elements.samples.children) button.setAttribute("aria-pressed", "false");
  blockIndex = 0;
  auditIndex = -1;
  scheduleRender();
});
elements.schema.addEventListener("input", () => { auditIndex = -1; scheduleRender(); });
for (const id of ["enable-json5", "enable-coercion", "enable-extraction"]) {
  elements[id].addEventListener("change", () => {
    if (playback && id === "enable-json5") {
      globalThis.moonLabStreamStart(elements[id].checked);
      globalThis.moonLabStreamPush(elements.source.value);
    }
    auditIndex = -1;
    blockIndex = 0;
    scheduleRender();
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
  pushTokens(1);
});
elements.replay.addEventListener("click", () => {
  startPlayback(playback?.target ?? elements.source.value);
  play();
});
elements.copy.addEventListener("click", async () => {
  const copied = await copyText(outputText, elements.output);
  elements["copy-label"].textContent = copied ? "Copied" : "Text selected";
  clearTimeout(copyTimer);
  copyTimer = setTimeout(() => { elements["copy-label"].textContent = "Copy JSON"; }, 1400);
});
elements["copy-retry"].addEventListener("click", async () => {
  const copied = await copyText(elements["retry-prompt"].textContent, elements["retry-prompt"]);
  elements["copy-retry"].textContent = copied ? "Copied" : "Text selected";
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
  const throughput = lane.ms > 0 ? (count * inputBytes / (lane.ms * 1000)).toFixed(2) + " MB/s" : "MB/s pending";
  elements[lane.id].textContent = (lane.success / count * 100).toFixed(0) + "%";
  elements[lane.id + "-detail"].textContent = median.toFixed(2) + " µs median · " + throughput;
}

elements.benchmark.addEventListener("click", async () => {
  const input = examples[0].input;
  const inputBytes = new TextEncoder().encode(input).length;
  const strict = (text) => {
    try { JSON.parse(text); return true; } catch { return false; }
  };
  const lanes = [
    { run: globalThis.moonLabRepairOnly, id: "bench-repair", results: [], success: 0, ms: 0 },
    { run: strict, id: "bench-strict", results: [], success: 0, ms: 0 },
  ];
  const total = 10_000;
  const batch = 250;
  elements.benchmark.disabled = true;
  elements["bench-state"].textContent = "Running on this device…";
  elements["bench-progress"].value = 0;
  try {
    for (const lane of lanes) benchBatch(lane.run, input, batch);
    for (let count = batch; count <= total; count += batch) {
      for (const lane of lanes) {
        const result = benchBatch(lane.run, input, batch);
        lane.results.push(result.ms * 1000 / batch);
        lane.ms += result.ms;
        lane.success += result.success;
        showBenchmarkBatch(lane, count, inputBytes);
      }
      elements["bench-progress"].value = count;
      await nextFrame();
    }
    elements["bench-state"].textContent = "10,000 attempts per engine";
  } catch (error) {
    elements["bench-state"].textContent = "Benchmark failed: " + error.message;
  } finally {
    elements.benchmark.disabled = false;
  }
});

loadSample(0);
