const compileOptions = { builtins: ["js-string"], importedStringConstants: "_" };
const numberPattern = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
const tokenPattern = /"(?:[^"\\]|\\[\s\S])*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/g;
const hasReviverSource = JSON.parse("0", (_key, _value, context) => context?.source) === "0";

/** An exact JSON number lexeme that cannot be represented as a plain safe integer. */
export class ExactJsonNumber {
  constructor(source) {
    if (typeof source !== "string" || !numberPattern.test(source)) {
      throw new TypeError("Expected the source text of a valid JSON number.");
    }
    this.source = source;
    Object.freeze(this);
  }

  toString() {
    return this.source;
  }
}

function exactNumber(value, source) {
  return Number.isSafeInteger(value) && String(value) === source
    ? value
    : new ExactJsonNumber(source);
}

function decodeWire(wire) {
  if (wire === "") throw new Error("Unknown Wasm stream handle.");
  if (hasReviverSource) {
    const payload = JSON.parse(wire, (_key, value, context) =>
      typeof value === "number" ? exactNumber(value, context.source) : value);
    return { ...payload, wire };
  }

  // Legacy JSON.parse revivers omit token sources. Mark numeric tokens first
  // using a key ensured to be absent even from escaped input strings.
  const strings = new Set();
  for (const [token] of wire.matchAll(tokenPattern)) {
    if (token.startsWith('"')) strings.add(JSON.parse(token));
  }
  let marker = "$exactNumber";
  while (strings.has(marker)) marker += "$";
  const key = JSON.stringify(marker);
  const marked = wire.replace(tokenPattern, token => token.startsWith('"')
    ? token
    : `{${key}:"${token}"}`);
  const payload = JSON.parse(marked, (_key, value) =>
    value && typeof value === "object" && Object.hasOwn(value, marker)
      ? exactNumber(Number(value[marker]), value[marker])
      : value);
  return { ...payload, wire };
}

function useText(value, label) {
  if (typeof value !== "string") throw new TypeError(`${label} must be a string.`);
  return value;
}

function readOptions({
  schema = "", json5 = false, ignoreThink = false, coerce = false,
  semantic = false, diagnostics = false, language = "en",
} = {}) {
  return {
    schema: useText(schema, "Schema JSON"), json5, ignoreThink,
    coerce: coerce || semantic, semantic, diagnostics, chinese: language === "zh",
  };
}

async function readWasm(url) {
  if (url.protocol === "file:" && globalThis.process?.versions?.node) {
    const { readFile } = await import("node:fs/promises");
    return readFile(url);
  }
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Cannot load Wasm GC SDK (${response.status}).`);
  return response.arrayBuffer();
}

function openStream(api, options) {
  const { schema, json5, coerce, ignoreThink, semantic, diagnostics, chinese } = readOptions(options);
  const handle = api.moonSdkStreamStart(schema, json5, coerce, ignoreThink, semantic, diagnostics, chinese);
  let closed = false;
  let final;
  function assertOpen() {
    if (closed) throw new Error("The repair stream is closed.");
  }
  function close() {
    if (closed) return;
    api.moonSdkStreamClose(handle);
    closed = true;
  }
  return Object.freeze({
    push(chunk) {
      assertOpen();
      return decodeWire(api.moonSdkStreamPush(handle, useText(chunk, "Chunk")));
    },
    preview() {
      if (final !== undefined) return final;
      assertOpen();
      return decodeWire(api.moonSdkStreamView(handle, false, false));
    },
    nextPatches() {
      assertOpen();
      return decodeWire(api.moonSdkStreamView(handle, true, false));
    },
    finalize() {
      if (final !== undefined) return final;
      assertOpen();
      try {
        final = decodeWire(api.moonSdkStreamView(handle, false, true));
        return final;
      } finally {
        close();
      }
    },
    close,
  });
}

/** Load the compiled MoonBit SDK. Each returned engine owns independent streams. */
export async function createRepairEngine({ wasm = new URL("./engine.wasm", import.meta.url) } = {}) {
  const input = wasm instanceof URL ? await readWasm(wasm) : wasm;
  let instance;
  try {
    instance = input instanceof WebAssembly.Module
      ? await WebAssembly.instantiate(input, {})
      : (await WebAssembly.instantiate(input, {}, compileOptions)).instance;
    if (typeof instance.exports.moonSdkStreamStart !== "function" ||
        !instance.exports.moonLabRepairOnly("{}")) {
      throw new TypeError("The module is missing the MoonBit SDK exports.");
    }
  } catch (cause) {
    throw new Error("Cannot initialize the MoonBit SDK. Wasm GC and JS string builtins are required.", { cause });
  }

  const api = instance.exports;
  function batch(source, options, extract) {
    const { schema, json5, coerce, ignoreThink, semantic, diagnostics, chinese } = readOptions(options);
    return decodeWire(api.moonLabRunWithOptions(
      useText(source, "Source"), schema, json5, coerce, extract, ignoreThink, semantic, diagnostics, chinese,
    ));
  }
  return Object.freeze({
    backend: "wasm-gc",
    repair: (source, options) => batch(source, options, false),
    extractAll: (source, options) => batch(source, options, true),
    createStream: options => openStream(api, options),
    guardMcpToolCall(source, registry, { json5 = false, coerce = false, ignoreThink = false } = {}) {
      return decodeWire(api.moonLabGuardMcp(
        useText(source, "Source"), useText(registry, "Tool schema registry JSON"), json5, coerce, ignoreThink,
      ));
    },
  });
}
