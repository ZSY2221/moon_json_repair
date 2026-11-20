"use strict";

const elements = Object.fromEntries([
  "samples", "stream", "stream-label", "source", "source-gutter", "source-meta",
  "source-state", "output", "output-wrap", "result-gutter", "repair-state",
  "elapsed", "copy", "copy-label", "audit-count", "audit-empty", "audit",
  "schema-state", "schema-summary", "schema-errors", "schema",
].map((id) => [id, document.getElementById(id)]));

let outputText = "";
let pendingFrame = 0;
let streamTimer = null;
let copyTimer = null;

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

function displayJson(json) {
  // Keep the exact number tokens returned by MoonBit. JSON.parse would round large integers.
  const tokens = json.match(/"(?:\\[\s\S]|[^"\\])*"|true|false|null|-?\d+(?:\.\d+)?(?:e[+-]?\d+)?|[{}\[\],:]/gi) ?? [];
  const fragment = document.createDocumentFragment();
  const parts = [];
  let depth = 0;
  const add = (text, kind = "") => {
    parts.push(text);
    fragment.append(kind ? node("span", `token-${kind}`, text) : text);
  };
  const lineBreak = () => add("\n" + "  ".repeat(depth));

  for (const [index, token] of tokens.entries()) {
    const next = tokens[index + 1];
    const previous = tokens[index - 1];
    if (token === "{" || token === "[") {
      add(token);
      depth += 1;
      if (next !== "}" && next !== "]") lineBreak();
    } else if (token === "}" || token === "]") {
      depth -= 1;
      if (previous !== "{" && previous !== "[") lineBreak();
      add(token);
    } else if (token === ",") {
      add(token);
      lineBreak();
    } else if (token === ":") {
      add(": ");
    } else if (token.startsWith('"')) {
      add(token, next === ":" ? "key" : "string");
    } else {
      add(token, /[tfn]/.test(token[0]) ? "literal" : "number");
    }
  }

  return { fragment, text: parts.join("") };
}

function showOutput(value, state, elapsed = "") {
  const pretty = state === "success" ? displayJson(value) : null;
  const output = elements.output;
  const wrap = elements["output-wrap"];
  const nextOutput = pretty?.text ?? "";
  if (outputText !== nextOutput) {
    clearTimeout(copyTimer);
    elements["copy-label"].textContent = "Copy";
  }
  outputText = nextOutput;
  output.replaceChildren(pretty?.fragment ?? value);
  wrap.dataset.error = String(state === "failure");
  wrap.dataset.empty = String(state === "idle");
  setGutter(elements["result-gutter"], outputText, wrap.scrollTop);
  const repairState = elements["repair-state"];
  repairState.className = state === "success" ? "good" : state === "failure" ? "bad" : "";
  repairState.textContent = { success: "✓  Valid JSON", failure: "Unable to repair", idle: "Awaiting input" }[state];
  elements.elapsed.textContent = elapsed;
  elements.copy.disabled = !pretty;
}

function showAudit(edits, emptyText) {
  elements["audit-count"].textContent = `${edits.length} ${edits.length === 1 ? "edit" : "edits"}`;
  elements["audit-empty"].hidden = edits.length > 0;
  elements["audit-empty"].textContent = emptyText;
  const rows = document.createDocumentFragment();
  for (const { action, kind, position, end_offset: endOffset } of edits) {
    const row = document.createElement("li");
    const button = document.createElement("button");
    const mark = node("span", "audit-mark", "↳");
    mark.setAttribute("aria-hidden", "true");
    const coordinate = node("span", "audit-position", `L${position.line}:C${position.column}`);
    const description = node("span", "audit-action", action);
    description.append(node("small", "audit-kind", kind));
    button.type = "button";
    button.append(mark, coordinate, description);
    button.addEventListener("click", () => {
      stopStream();
      elements.source.focus();
      elements.source.setSelectionRange(position.offset, endOffset);
    });
    row.append(button);
    rows.append(row);
  }
  elements.audit.replaceChildren(rows);
}

function showSchema(state, badge, summary, errors = []) {
  const status = elements["schema-state"];
  status.dataset.state = state;
  status.textContent = badge;
  elements["schema-summary"].textContent = summary;
  const rows = document.createDocumentFragment();
  for (const { path, message, keyword } of errors) {
    const row = document.createElement("li");
    row.append(node("code", "schema-path", `${path}  ·  ${keyword}`), node("span", "", message));
    rows.append(row);
  }
  elements["schema-errors"].replaceChildren(rows);
}

function render() {
  const { value: source, scrollTop } = elements.source;
  const lines = setGutter(elements["source-gutter"], source, scrollTop);
  elements["source-meta"].textContent = `${lines} ${lines === 1 ? "line" : "lines"}  ·  ${source.length} UTF-16 units`;
  elements.stream.disabled = !source && !streamTimer;

  if (typeof globalThis.moonRepairPayload !== "function") {
    showOutput("Cannot load the MoonBit engine. Rebuild it with node web/build.mjs.", "failure");
    showAudit([], "Repair output will appear after the engine loads.");
    showSchema("idle", "Pending", "Load the engine to run validation.");
    return;
  }

  const schema = elements.schema.value.trim();
  if (!source.trim()) {
    showOutput("Repaired JSON will appear here.", "idle");
    showAudit([], "Enter tool-call output to see the edits.");
    showSchema("idle", "Pending", "Validation runs as soon as repaired JSON is available.");
    return;
  }

  const start = performance.now();
  const outcome = JSON.parse(globalThis.moonRepairPayload(source, schema));
  const elapsed = `${(performance.now() - start).toFixed(2)} ms`;
  if (!outcome.ok) {
    const { kind, message, position } = outcome.error;
    showOutput(`${message}\n\n${kind} · line ${position.line}, column ${position.column}`, "failure", elapsed);
    showAudit([], "The engine could not produce a repair report for this input.");
    showSchema("idle", "Pending", "Validation needs a repaired JSON value.");
    return;
  }

  const { report, validation } = outcome;
  showOutput(report.json, "success", elapsed);
  showAudit(report.edits, "The input was already valid JSON.");
  if (validation.state === "skipped") {
    showSchema("idle", "Skipped", "Add a schema to validate the repaired value.");
  } else if (validation.state === "invalid_json") {
    showSchema("fail", "Invalid schema", validation.message);
  } else if (validation.errors.length > 0) {
    const count = validation.errors.length;
    showSchema("fail", "Fail", `${count} ${count === 1 ? "constraint error" : "constraint errors"}`, validation.errors);
  } else {
    showSchema("pass", "Pass", "The repaired value satisfies the current schema.");
  }
}

function scheduleRender() {
  if (!pendingFrame) pendingFrame = requestAnimationFrame(() => {
    pendingFrame = 0;
    render();
  });
}

function stopStream(state = "Editable input") {
  if (streamTimer !== null) clearInterval(streamTimer);
  streamTimer = null;
  elements.stream.dataset.running = "false";
  elements["stream-label"].textContent = "Simulate stream";
  elements["source-state"].textContent = state;
}

function loadSample(index) {
  const { input, schema } = examples[index];
  stopStream();
  Array.from(elements.samples.children).forEach((button, buttonIndex) => {
    button.setAttribute("aria-pressed", String(buttonIndex === index));
  });
  elements.source.value = input;
  elements.schema.value = JSON.stringify(schema, null, 2);
  elements.source.scrollTop = 0;
  elements["output-wrap"].scrollTop = 0;
  scheduleRender();
}

for (const [index, sample] of examples.entries()) {
  const button = node("button", "", sample.label);
  button.type = "button";
  button.addEventListener("click", () => loadSample(index));
  elements.samples.append(button);
}

elements.source.addEventListener("input", () => {
  stopStream();
  for (const button of elements.samples.children) button.setAttribute("aria-pressed", "false");
  scheduleRender();
});
elements.schema.addEventListener("input", scheduleRender);
elements.source.addEventListener("scroll", () => { elements["source-gutter"].scrollTop = elements.source.scrollTop; });
elements["output-wrap"].addEventListener("scroll", () => { elements["result-gutter"].scrollTop = elements["output-wrap"].scrollTop; });

elements.stream.addEventListener("click", () => {
  if (streamTimer !== null) {
    stopStream("Stream stopped");
    return;
  }
  const input = Array.from(elements.source.value);
  const chunkSize = Math.max(1, Math.ceil(input.length / 40));
  let next = 0;
  elements.source.value = "";
  elements.stream.dataset.running = "true";
  elements["stream-label"].textContent = "Stop stream";
  elements["source-state"].textContent = "Receiving tokens…";
  streamTimer = setInterval(() => {
    elements.source.value += input.slice(next, next + chunkSize).join("");
    next += chunkSize;
    elements.source.scrollTop = elements.source.scrollHeight;
    if (next >= input.length) stopStream("Stream complete");
    scheduleRender();
  }, 50);
  scheduleRender();
});

elements.copy.addEventListener("click", async () => {
  let copied = false;
  try {
    await navigator.clipboard.writeText(outputText);
    copied = true;
  } catch {
    const range = document.createRange();
    const selection = window.getSelection();
    range.selectNodeContents(elements.output);
    selection.removeAllRanges();
    selection.addRange(range);
    copied = document.execCommand("copy");
    if (copied) selection.removeAllRanges();
  }
  elements["copy-label"].textContent = copied ? "Copied" : "Text selected";
  clearTimeout(copyTimer);
  copyTimer = setTimeout(() => { elements["copy-label"].textContent = "Copy"; }, 1400);
});

loadSample(0);
