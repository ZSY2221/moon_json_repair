import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { corpus } from "../corpus/cases.mjs";

const source = readFileSync(new URL("../web/engine.js", import.meta.url), "utf8");
const sandbox = {};
runInNewContext(source, sandbox);
assert.equal(typeof sandbox.moonLabRun, "function", "Run node web/build.mjs before evaluating the corpus");
assert.ok(corpus.length >= 24);
assert.equal(new Set(corpus.map(({ id }) => id)).size, corpus.length);

const groupResults = new Map();
const failures = [];
const metricNames = [
  "cases", "recoverable", "strictAccepted", "strictRecovered", "strictExact",
  "repairRecovered", "repairExact", "guarded", "guardsCorrect", "schemas", "schemasExact", "exactOutcomes",
];
const counters = () => Object.fromEntries(metricNames.map(key => [key, 0]));
const totals = counters();
for (const fixture of corpus) {
  const group = groupResults.get(fixture.group) ?? { group: fixture.group, ...counters() };
  groupResults.set(group.group, group);
  const count = metric => { totals[metric]++; group[metric]++; };
  count("cases");
  if (fixture.output) count("recoverable");
  if (fixture.error) count("guarded");
  if (fixture.schema) count("schemas");
  try {
    const strict = JSON.stringify(JSON.parse(fixture.source));
    count("strictAccepted");
    if (fixture.output?.length === 1) {
      count("strictRecovered");
      if (strict === fixture.output[0]) count("strictExact");
    }
  } catch { /* A strict JSON.parse syntax rejection is an observation. */ }

  const flags = [fixture.json5, fixture.coerce, fixture.extract, fixture.ignoreThink].map(Boolean);
  const result = JSON.parse(sandbox.moonLabRun(
    fixture.source, fixture.schema ? JSON.stringify(fixture.schema) : "", ...flags,
  ));
  try {
    if (fixture.error) {
      assert.equal(result.ok, false);
      assert.equal(result.error.kind, fixture.error);
      count("guardsCorrect");
    } else {
      if (result.ok && result.blocks.length === fixture.output.length) {
        for (const block of result.blocks) JSON.parse(block.output);
        count("repairRecovered");
      }
      assert.equal(result.ok, true, result.error?.message);
      assert.deepEqual(result.blocks.map(block => block.output), fixture.output, "exact text, precision, and cardinality");
      count("repairExact");
      if (fixture.ignored !== undefined) {
        const edits = result.blocks.flatMap(block => block.report.edits).filter(edit => edit.kind === "ignore_think_block");
        assert.equal(edits.length, fixture.ignored, "each reasoning range receives one audit");
        for (const edit of edits) {
          assert.match(fixture.source.slice(edit.position.offset, edit.end_offset), /^<think>/i);
          assert.equal(edit.replacement, "");
        }
      }
      if (fixture.schema) {
        const block = result.blocks[0];
        assert.deepEqual(block.validation.errors.map(({ path, keyword }) => [path, keyword]), fixture.errors);
        assert.deepEqual(block.coercions.map(({ path }) => path), fixture.coercions ?? []);
        if (fixture.retry) assert.ok(block.retry_prompt.includes(fixture.retry), "retry pinpoints the failing path");
        else assert.equal(block.retry_prompt, "");
        count("schemasExact");
      }
    }
    count("exactOutcomes");
  } catch (error) {
    failures.push({ id: fixture.id, failure: error.message, observed: result.ok ? result.blocks.map(block => block.output) : result.error?.kind });
  }
}

const result = { totals, groups: [...groupResults.values()], failures };
if (process.argv.includes("--json")) console.log(JSON.stringify(result, null, 2));
else {
  console.table([...groupResults.values()].map(({ group, cases, recoverable, strictAccepted, strictRecovered, strictExact, repairRecovered, repairExact, guardsCorrect, schemasExact }) =>
    ({ group, cases, recoverable, strictAccepted, strictRecovered, strictExact, repairRecovered, repairExact, guardsCorrect, schemasExact })));
  console.log(JSON.stringify(totals));
  for (const failure of failures) console.error(failure);
}
if (failures.length) process.exitCode = 1;
