"use strict";

const duelDraft = [
  "<thi",
  'nk>\n{"tool":"scratch","args":{"title":"Draft only"}}\n',
  "</th",
  "ink>\n",
];
const duelDraftLength = duelDraft.join("").length;

function duelChunks(fixture) {
  return [...duelDraft, ...fixture.chunks];
}

function duelJsonPrefix(source) {
  // The fixed replay fixture defines a transport boundary after the draft.
  // The strict lane still gets malformed JSON prefixes as they arrive.
  return source.slice(duelDraftLength);
}

const duelFixtures = {
  travel: {
    chunks: [
      '{"tool":"plan_trip","args":{',
      '"title":"Weekend', ' in Osaka",',
      '"destination":"Osaka",',
      '"budget":', '680,',
      '"risk":"low",',
      '"completion":', '100',
      '}', '}',
    ],
    fields: [
      { key: "title", label: "Trip title", kind: "title" },
      { key: "destination", label: "Destination" },
      { key: "budget", label: "Budget" },
      { key: "risk", label: "Risk" },
      { key: "completion", label: "Progress", kind: "progress" },
    ],
  },
  checkout: {
    chunks: [
      '{"tool":"create_order","args":{',
      '"title":"Order', ' for two monitors",',
      '"amount":', '419.90,',
      '"currency":"USD",',
      '"risk":"review",',
      '"order_id":9007199254740993',
      '}', '}',
    ],
    fields: [
      { key: "title", label: "Order title", kind: "title" },
      { key: "amount", label: "Amount" },
      { key: "currency", label: "Currency" },
      { key: "risk", label: "Risk" },
      { key: "order_id", label: "Order ID" },
    ],
  },
  write: {
    chunks: [
      '{"tool":"write_file","args":{',
      '"path":"src/main.mbt",',
      '"content":"fn main {\\n',
      '  let value = 9007199254740993\\n',
      '  println(value)\\n',
      '}\\n",',
      '"bytes":', '73',
      '}', '}',
    ],
    fields: [
      { key: "path", label: "File path", kind: "title" },
      { key: "content", label: "Code preview", kind: "code" },
      { key: "bytes", label: "Estimated size" },
    ],
  },
};

const chaosTotal = 1_152;
const chaosSeed = 0x05eeda11;

function makeChaosCases(seed = chaosSeed, count = chaosTotal) {
  let state = seed >>> 0;
  function pick(length) {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) % length;
  }
  const kinds = ["truncated", "escape", "reasoning", "quotes", "nesting", "duplicate"];
  return Array.from({ length: count }, (_, index) => {
    const kind = kinds[index % kinds.length];
    const id = String(9_007_199_254_740_993n + BigInt(index));
    const name = ["Osaka", "台北", "München", "🌙", "A/B"][pick(5)];
    const payload = '{"tool":"record","args":{"id":' + id + ',"name":' + JSON.stringify(name) + '}}';
    let source;
    switch (kind) {
      case "truncated":
        source = payload.slice(0, payload.length - 1 - pick(7));
        break;
      case "escape":
        source = '{"value":"' + ["\\uD800", "\\uDE00", "\\uD83D\\uDE00", "\\q", "\\" + String.fromCharCode(0xd800)][pick(5)] + '","id":' + id + '}';
        break;
      case "reasoning": {
        const marker = pick(2) === 0 ? "think" : "THINK";
        source = "<" + marker + ">\n<think>{'draft':'unfinished\n</think>\n" +
          '{"ignored":"candidate"}' + "\n</" + marker + ">\n" + payload;
        break;
      }
      case "quotes":
        source = "{name:'" + name + "',notes:'say \"hi\"',active:True,}";
        break;
      case "nesting": {
        const depth = 210 + pick(110);
        source = "[".repeat(depth) + id + "]".repeat(Math.max(0, depth - pick(4)));
        break;
      }
      default:
        source = '{"id":' + id + ',"\\u0069d":' + (BigInt(id) + 1n) + '}';
    }
    return { source, kind, json5: kind === "quotes", ignoreThink: kind === "reasoning" };
  });
}

// A negative response is counted only if the MoonBit bridge supplies an
// actual error object. Invalid envelopes and thrown traps have a separate bin.
function classifyChaosReport(raw) {
  try {
    const result = JSON.parse(raw);
    if (result.ok === false && result.error?.kind && Number.isInteger(result.error.position?.offset)) return "refused";
    if (result.ok !== true || !result.blocks?.length) return "panic";
    for (const block of result.blocks) {
      if (typeof block.report?.json !== "string") return "panic";
      JSON.parse(block.report.json);
    }
    return "repaired";
  } catch {
    return "panic";
  }
}

function duelFieldText(model, pointer) {
  const span = model.pointers.get(pointer);
  if (!span) return null;
  const value = model.text.slice(span.start, span.end);
  // JSON.parse is used only to decode string literals, preserving number text.
  return value.startsWith('"') ? JSON.parse(value) : value;
}

function applyDuelOperations(fields, trace, fixture) {
  if (!trace?.patches.length) return;
  const wire = jsonView(trace.patches_json);
  for (const [index, operation] of trace.patches.entries()) {
    for (const { key } of fixture.fields) {
      const pointer = "/args/" + key;
      const path = operation.path;
      if (path !== pointer && path !== "/args" && path !== "") continue;
      const value = operation.op === "remove"
        ? null : duelFieldText(wire, "/" + index + "/value" + pointer.slice(path.length));
      if (value === null) fields.delete(key);
      else fields.set(key, value);
    }
  }
}

function paintDuelFields(parent, fixture, fields, seals) {
  const fragment = document.createDocumentFragment();
  for (const { key, label, kind } of fixture.fields) {
    const value = fields.get(key);
    if (value === undefined || value === null || value === "") continue;
    const row = node("div", "duel-field", "");
    row.dataset.field = key;
    row.dataset.sealed = String(seals.has("/args/" + key));
    if (kind) row.classList.add("duel-" + kind);
    const caption = localizedNode("span", "duel-field-label", label);
    const badge = localizedNode("span", "field-state", row.dataset.sealed === "true" ? "sealed" : "streaming");
    const body = node(kind === "code" ? "pre" : "strong", "duel-field-value", value);
    if (key === "risk" && (value === "low" || value === "review")) {
      row.dataset.risk = value;
      labSet(body, value === "low" ? "Low risk" : "Needs review");
    }
    if (kind === "code") {
      const tokens = value.split(/(\b(?:fn|let|println)\b|\b[0-9]+\b)/u);
      body.replaceChildren(...tokens.map((part, index) => index % 2
        ? node("span", /^\d/u.test(part) ? "token-number" : "token-literal", part)
        : document.createTextNode(part)));
    }
    if (kind === "progress") {
      const progress = document.createElement("progress");
      progress.max = 100;
      progress.value = Number(value) || 0;
      labBind(progress, () => labText(label), "aria-label");
      body.replaceChildren(String(value) + "%", progress);
    }
    row.append(caption, badge, body);
    fragment.append(row);
  }
  if (!fragment.childElementCount) fragment.append(localizedNode("p", "duel-wait", "No fields available yet"));
  parent.replaceChildren(fragment);
}

function arenaStatus(element, state, message, ...args) {
  element.dataset.state = state;
  labSet(element, message, ...args);
}

let duelEnginePromise;
let duelPlayback = 0;
let lastChaosRefusal = null;
const arenaNode = id => document.getElementById(id);

function resetDuel() {
  duelPlayback++;
  arenaNode("duel-run").disabled = false;
  arenaNode("duel-fixture").disabled = false;
  const fixture = duelFixtures[arenaNode("duel-fixture").value];
  const empty = new Map();
  const unsealed = new Set();
  paintDuelFields(arenaNode("duel-strict-arguments"), fixture, empty, unsealed);
  paintDuelFields(arenaNode("duel-arguments"), fixture, empty, unsealed);
  arenaStatus(arenaNode("duel-strict-status"), "pending", "Waiting to start");
  arenaStatus(arenaNode("duel-wasm-status"), "pending", "Waiting to start");
  arenaStatus(arenaNode("duel-progress"), "ready", "Ready to play");
  arenaNode("duel-patch-count").dataset.count = "0";
  arenaNode("duel-input").textContent = "";
  labSet(arenaNode("duel-patch-count"), "{0} Patch ops", 0);
  labSet(arenaNode("duel-field-lag"), "First field · Wasm {0} · strict {1}", "—", "—");
  labSet(arenaNode("duel-engine-time"), "Engine time · Wasm {0} · strict {1}", "—", "—");
}

async function runDuel() {
  const button = arenaNode("duel-run");
  const select = arenaNode("duel-fixture");
  const fixture = duelFixtures[select.value];
  const chunks = duelChunks(fixture);
  resetDuel();
  const playbackId = duelPlayback;
  button.disabled = select.disabled = true;
  const status = arenaNode("duel-progress");
  const strictStatus = arenaNode("duel-strict-status");
  const wasmStatus = arenaNode("duel-wasm-status");
  arenaStatus(status, "running", "Preparing Wasm GC…");
  try {
    await wasmReady;
    if (playbackId !== duelPlayback) return;
    if (!wasmEngine) {
      arenaStatus(status, "unavailable", "Wasm GC is unavailable in this browser.");
      return;
    }
    duelEnginePromise ??= createWasmEngine();
    const engine = await duelEnginePromise;
    if (playbackId !== duelPlayback) return;
    engine.start(false, true);
    const fields = new Map();
    let source = "";
    let patchCount = 0;
    let wasmTime = 0;
    let strictTime = 0;
    let wasmFirst = null;
    let strictFirst = null;
    const started = performance.now();
    for (const [index, chunk] of chunks.entries()) {
      if (index > 0) await new Promise(resolve => setTimeout(resolve, 190));
      if (playbackId !== duelPlayback) return;
      source += chunk;
      arenaNode("duel-input").textContent = source;
      const strictStarted = performance.now();
      const payload = duelJsonPrefix(source);
      let complete = false;
      try { JSON.parse(payload); complete = true; } catch { /* The prefix is still incomplete. */ }
      strictTime += performance.now() - strictStarted;
      if (complete) {
        strictFirst ??= performance.now() - started;
        const strict = jsonView(payload);
        const values = new Map(fixture.fields.map(({ key }) => [key, duelFieldText(strict, "/args/" + key)]));
        const sealed = new Set(fixture.fields.map(({ key }) => "/args/" + key));
        paintDuelFields(arenaNode("duel-strict-arguments"), fixture, values, sealed);
        arenaStatus(strictStatus, "ready", "Complete JSON");
      } else {
        arenaStatus(strictStatus, "waiting", payload ? "Waiting for complete JSON" : "Waiting for the JSON payload");
      }
      const engineStarted = performance.now();
      if (!engine.push(chunk)) throw new Error("Duel stream stopped");
      const final = index + 1 === chunks.length;
      const raw = engine.view(source, "", false, false, final);
      wasmTime += performance.now() - engineStarted;
      const trace = JSON.parse(raw).blocks?.[0]?.trace;
      applyDuelOperations(fields, trace, fixture);
      patchCount += trace?.patches.length ?? 0;
      if (Array.from(fields.values()).some(value => value !== "")) wasmFirst ??= performance.now() - started;
      const sealed = new Set(trace?.fields.filter(field => field.sealed).map(field => field.pointer));
      paintDuelFields(arenaNode("duel-arguments"), fixture, fields, sealed);
      arenaStatus(wasmStatus, final ? "ready" : "waiting",
        final ? "Complete JSON" : payload ? "Applying live patches" : "Isolating the reasoning draft");
      arenaNode("duel-patch-count").dataset.count = String(patchCount);
      labSet(arenaNode("duel-patch-count"), "{0} Patch ops", patchCount);
      const ms = value => value === null ? "—" : value.toFixed(1) + " ms";
      labSet(arenaNode("duel-field-lag"), "First field · Wasm {0} · strict {1}", ms(wasmFirst), ms(strictFirst));
      labSet(arenaNode("duel-engine-time"), "Engine time · Wasm {0} · strict {1}", ms(wasmTime), ms(strictTime));
      arenaStatus(status, final ? "complete" : "running", "{0}/{1} chunks", index + 1, chunks.length);
    }
  } catch {
    duelEnginePromise = undefined;
    if (playbackId === duelPlayback) arenaStatus(status, "error", "Duel stream stopped");
  } finally {
    if (playbackId === duelPlayback) button.disabled = select.disabled = false;
  }
}

function showChaosDiagnostic() {
  if (!lastChaosRefusal || !wasmEngine?.runOptions) return;
  try {
    const sample = lastChaosRefusal;
    const raw = wasmEngine.runOptions(sample.source, "", sample.json5, false, false, sample.ignoreThink, false, true, labLanguage === "zh");
    const parsed = JSON.parse(raw);
    const diagnostic = parsed.diagnostic ?? parsed.blocks?.[0]?.diagnostic;
    if (typeof diagnostic !== "string" || !diagnostic) return;
    const card = arenaNode("chaos-diagnostic-card");
    if (card.hidden) card.open = true;
    card.hidden = false;
    arenaNode("chaos-diagnostic").textContent = diagnostic;
  } catch { /* Displaying an example does not change the measured counts. */ }
}

async function runChaos() {
  const button = arenaNode("chaos-run");
  const progress = arenaNode("chaos-progress");
  const status = arenaNode("chaos-status");
  button.disabled = true;
  progress.value = 0;
  lastChaosRefusal = null;
  arenaNode("chaos-diagnostic-card").hidden = true;
  for (const name of ["processed", "repaired", "refused", "panics"]) arenaNode("chaos-" + name).textContent = "0";
  arenaNode("chaos-throughput").textContent = "—";
  arenaStatus(status, "running", "Preparing Wasm GC…");
  try {
    await wasmReady;
    if (!wasmEngine) {
      arenaStatus(status, "unavailable", "Wasm GC is unavailable in this browser.");
      return;
    }
    const samples = makeChaosCases();
    const counts = { repaired: 0, refused: 0, panic: 0 };
    const encoder = new TextEncoder();
    let elapsed = 0;
    let bytes = 0;
    for (let position = 0; position < samples.length;) {
      await nextFrame();
      const deadline = performance.now() + 8;
      const end = Math.min(samples.length, position + 24);
      do {
        const sample = samples[position++];
        bytes += encoder.encode(sample.source).length;
        const started = performance.now();
        let raw;
        try { raw = wasmEngine.run(sample.source, "", sample.json5, false, false, sample.ignoreThink); }
        catch { /* A thrown bridge exception counts as a failure. */ }
        elapsed += performance.now() - started;
        const result = classifyChaosReport(raw);
        counts[result]++;
        if (result === "refused" && !lastChaosRefusal) {
          lastChaosRefusal = sample;
          showChaosDiagnostic();
        }
      } while (position < end && performance.now() < deadline);
      progress.value = position;
      arenaNode("chaos-processed").textContent = String(position);
      arenaNode("chaos-repaired").textContent = String(counts.repaired);
      arenaNode("chaos-refused").textContent = String(counts.refused);
      arenaNode("chaos-panics").textContent = String(counts.panic);
      arenaNode("chaos-throughput").textContent = elapsed > 0 ? (bytes / (elapsed * 1000)).toFixed(2) + " MB/s" : "—";
      arenaStatus(status, position === samples.length ? "complete" : "running", "{0}/{1} cases checked", position, samples.length);
    }
  } catch {
    arenaStatus(status, "error", "Chaos Arena could not finish");
  } finally {
    button.disabled = false;
  }
}

function connectArena() {
  arenaNode("duel-run").addEventListener("click", runDuel);
  arenaNode("duel-fixture").addEventListener("change", resetDuel);
  arenaNode("chaos-run").addEventListener("click", runChaos);
  resetDuel();
}
