import { createRepairEngine, ExactJsonNumber } from "../../packages/json-repair-wasm/index.mjs";
import type { Block, PatchTrace } from "../../packages/json-repair-wasm/index.mjs";

const engine = await createRepairEngine();
const stream = engine.createStream({ ignoreThink: true });
const chunks = [
  '<think>Draft calculation</think>\n{"name":"write_file","arguments":{',
  '"id":9007199254740993,"path":"report',
  '.md"}}',
];
for (const chunk of chunks) {
  const pushed = stream.push(chunk);
  if (!pushed.ok) throw new Error(pushed.error.message);
  const frame = stream.nextPatches();
  if (!frame.ok) throw new Error(frame.error.message);
  const trace: PatchTrace = frame.blocks[0].trace;
  console.log(trace.patches_json);
}

const result = stream.finalize();
if (!result.ok) throw new Error(result.error.message);
const final: Block = result.blocks[0];
const value = final.value as { arguments: { id: ExactJsonNumber } };
if (!(value.arguments.id instanceof ExactJsonNumber) ||
    value.arguments.id.source !== "9007199254740993") {
  throw new Error("Expected the unrounded integer from Wasm GC.");
}
console.log(final.output);
