import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const pins = {
  "1.5.2": {
    commit: "83307c4555b6e3f3e849290a621176c450552e57",
    registry: "0.14.0",
    entry: "63e3d524f4fd6c1825e8b1b33c95e04e9c4ed115",
    engine: "9fc9c953abcdcc61a0c74337cc4674de55f9e41c",
  },
  "1.5.3": {
    commit: "e03e68eb2a5d6a1f8f28df77a5840ef6bd9e9554",
    registry: "0.15.0",
    entry: "5ce3f7f6be53fea47f7b67f9ae0cb4f90cd90913",
    engine: "b1a8721ad5cf365a588bce9e0065ed27ebe77db6",
  },
};

const [entryPath, fixturePath, ...extra] = process.argv.slice(2);
assert.ok(entryPath && !extra.length,
  "Usage: node tools/verify-liwenjson-baseline.mjs EXTERNAL_INDEX_CJS [FIXTURE_DIRECTORY]");
const entry = resolve(entryPath);
const fixtures = fixturePath ? resolve(fixturePath) :
  fileURLToPath(new URL("../_build/differentiation/", import.meta.url));
const packageDirectory = dirname(entry);
const manifest = JSON.parse(readFileSync(join(packageDirectory, "package.json"), "utf8"));
assert.equal(manifest.name, "liwenjson");
const pin = pins[manifest.version];
assert.ok(pin, "Expected a supported pinned LIWENJSON package version");

function gitBlob(path) {
  const bytes = readFileSync(path);
  return createHash("sha1").update(`blob ${bytes.length}\0`).update(bytes).digest("hex");
}

assert.equal(gitBlob(entry), pin.entry, "LIWENJSON entry does not match pinned source");
assert.equal(gitBlob(join(packageDirectory, "vendor", "liwenjson.js")), pin.engine,
  "LIWENJSON bundled engine does not match pinned source");
const baseline = createRequire(import.meta.url)(entry);
assert.equal(baseline.version, manifest.version);

const fixtureHashes = {};
function fixture(name) {
  const bytes = readFileSync(join(fixtures, name));
  fixtureHashes[name] = createHash("sha256").update(bytes).digest("hex");
  return bytes.toString("utf8");
}

function plan(input, schemaJson) {
  const result = baseline.analyze(input, { profile: "agent", schemaJson });
  return {
    decision: result.decision,
    executable: result.executable,
    exactness: result.exactness,
    error: result.error,
    refusal: result.refusal ?? null,
    schemaMissing: result.schema_missing,
    repairs: result.repairs.map(({ rule, name }) => ({ rule, name })),
    text: result.text,
    retry: result.retry?.prompt ?? null,
  };
}

function safeProbe(probe) {
  try {
    return probe();
  } catch (error) {
    if (typeof error.code !== "string" || !/^E\d+$/.test(error.code)) throw error;
    return { error: { code: error.code, message: error.message } };
  }
}

const reasoning = fixture("01-think.txt");
const semanticInput = fixture("02-schema-input.json");
const semanticDeclaration = fixture("02-schema.json");
const streamInput = fixture("03-write-file.txt");
assert.equal(Buffer.byteLength(streamInput), 50_000);
const chunkSize = 64;
const firstSnapshot = baseline.snapshot(streamInput, chunkSize);
const finalSnapshot = baseline.snapshot(streamInput, streamInput.length);
const finalDeltas = baseline.deltas(streamInput, streamInput.length).deltas;
assert.ok(Array.isArray(finalDeltas), "Expected the LIWENJSON delta list");
const requestedTools = JSON.parse(fixture("04-tools.json"));

// The npm entry accepts argument documents. Hash the transport fixtures for
// cross-reference and test exact argument substrings without JS number parsing.
const mcpInput = fixture("04-mcp.ndjson");
const providerInput = fixture("04-provider.sse");
const readRow = mcpInput.split(/\r?\n/).find(line => line.includes('"name":"read_invoice"'));
const negativeRow = mcpInput.split(/\r?\n/).find(line => line.includes('"id":"amount-1"'));
assert.ok(readRow && negativeRow);
function rawArguments(row) {
  const captured = /"arguments":(\{.*\})\}\}$/.exec(row)?.[1];
  assert.ok(captured, "Expected object arguments in the fixture row");
  return captured;
}

const output = {
  provenance: {
    repository: "wenhuang2333/LIWENJSON",
    version: manifest.version,
    npmEngine: "MoonBit JS bundle",
    node: process.version,
    ...pin,
  },
  fixtureHashes,
  reasoning: {
    agent: safeProbe(() => plan(reasoning)),
    permissiveRepairedText: safeProbe(() => baseline.repair(reasoning, { profile: "permissive" })),
  },
  semantic: safeProbe(() => plan(semanticInput, semanticDeclaration)),
  stream: {
    chunkSize,
    chunkCount: Math.ceil(streamInput.length / chunkSize),
    firstSnapshot: { completeness: firstSnapshot.completeness, tool: firstSnapshot.value?.tool },
    finalSnapshot: { completeness: finalSnapshot.completeness, id: finalSnapshot.value?.args?.id },
    emittedOperations: [...new Set(finalDeltas.map(delta => delta.op))],
    deltaCount: finalDeltas.length,
    finalIdDeltas: finalDeltas.filter(delta => delta.pointer === "/args/id"),
    repairedTextKeepsExactId: /"id":9007199254740993[},]/.test(baseline.repair(streamInput)),
    measurement: "npm prefix-query and final-output check",
  },
  transport: {
    probe: "argument documents extracted from two existing MCP frames",
    rawMcpBytes: Buffer.byteLength(mcpInput),
    rawProviderSseBytes: Buffer.byteLength(providerInput),
    knownTool: safeProbe(() => plan(rawArguments(readRow), JSON.stringify(requestedTools.read_invoice))),
    invalidAmount: safeProbe(() => plan(rawArguments(negativeRow), JSON.stringify(requestedTools.create_invoice))),
    invalidAmountWithoutSchema: safeProbe(() => plan(rawArguments(negativeRow))),
  },
};
console.log(JSON.stringify(output, null, 2));
