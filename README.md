# moon_json_repair

[简体中文](README.zh-CN.md) · [Live Bilingual Playground](https://zsy2221.github.io/moon_json_repair/?lang=en) · [Mooncakes v0.5.0 Docs](https://mooncakes.io/docs/ZSY2221/json_repair%400.5.0) · [JS/TS Wasm GC SDK](https://github.com/ZSY2221/moon_json_repair/tree/main/packages/json-repair-wasm) · [![CI](https://github.com/ZSY2221/moon_json_repair/actions/workflows/ci.yml/badge.svg)](https://github.com/ZSY2221/moon_json_repair/actions/workflows/ci.yml)

Repair incomplete JSON from model streams and tool calls while preserving numeric lexemes such as `9007199254740993`. Inspect edits at their original UTF-16 positions, replay RFC 6902 patches, or validate arguments before invoking tools. A single MoonBit implementation supports **Wasm GC, JS, and Native**, with zero external MoonBit modules or project FFI.

Version **0.5.0** combines source diagnostics, opt-in schema recovery, a zero-runtime-dependency Wasm GC SDK, and an offline bilingual playground. The live UI comparison shows what can render from incomplete tool arguments. The seeded Chaos Arena reports legal repairs, protective refusals, and runtime failures separately.

| Local verification | Result |
| --- | --- |
| Wasm GC / JS | **908 passing tests each** · **99.69%** Wasm GC core coverage |
| Corpus | **248** RFC 8259 fixtures · **44** reconstructed model faults · **7,264** fixed-seed core cases |
| 50 KB streaming, 64 UTF-16 units | **251.99× JS** and **11.88× Wasm GC** for cached preview against each backend's full-prefix reference |
| Wasm GC SDK | **12** Node 24 tests, exact decimal JSON, **90,604 B** gzip engine |
| Bilingual Chaos Arena | **1,152** matching JS/Wasm GC outcomes in Node · 0 bridge failures |

## Choose an entry point

| Workload | Entry point | Result |
| --- | --- | --- |
| One interrupted JSON document | [`repair`](#quick-start) | Compact JSON, AST, and an edit audit |
| A tool call still streaming | [`RepairStream::next_patches`](#live-patches) | RFC 6902 operations and field closure states |
| Prose, fences, or reasoning around a reply | [`extract_all_with_policy`](#extraction-and-reasoning) | Separate documents and source spans |
| SSE tool-call events | [`--sse --emit-patches`](#sse-gateway) | Per-call NDJSON patch and completion events |
| MCP tool invocation | [`guard_mcp_tool_call`](#mcp-guard) or `--mcp-guard` | A forward frame or a JSON-RPC error |

## Quick start

Install the official MoonBit toolchain. Run this command in the consuming module once version 0.5.0 is available in the registry. [MoonBit downloads](https://www.moonbitlang.com/download/)

```sh
moon add ZSY2221/json_repair@0.5.0
```

Add the import to the consumer's `moon.pkg` and put the examples below in `readme_test.mbt`. Use a regular import block for production source files.

```moonbit
import {
  "ZSY2221/json_repair" @json_repair,
} for "test"
```

```moonbit
test "five-line tool call repair" {
  let report = @json_repair.repair("{amount:42").unwrap()
  let schema : Json = { "required": ["amount"] }
  assert_true(@json_repair.validate(report.value, schema).is_empty())
}
```

```moonbit
///|
test "repair and validate a tool call" {
  let input =
    #|{tool:'quote', args:{amount:125.50,currency:'SGD'
  guard @json_repair.repair(input) is Ok(report) else {
    fail("expected a repairable tool call")
  }
  let schema : Json = {
    "type": "object",
    "required": ["tool", "args"],
    "properties": {
      "tool": { "enum": ["quote"] },
      "args": {
        "type": "object",
        "required": ["amount", "currency"],
        "properties": {
          "amount": { "type": "number", "minimum": 0 },
          "currency": { "enum": ["SGD", "USD"] },
        },
      },
    },
  }
  assert_eq(
    report.json,
    (
      #|{"tool":"quote","args":{"amount":125.50,"currency":"SGD"}}
    ),
  )
  assert_true(!report.edits.is_empty())
  assert_true(@json_repair.validate(report.value, schema).is_empty())
}
```

```sh
moon test --deny-warn
```

### Streaming preview

Call `push` with each transport chunk and choose `preview` for the complete current report, `status` for lexical framing, or `next_patches` for the patch and closure state. `finalize` seals the stream. Call `reset` before reusing it for another document.

Direct JSON continuations reuse the committed parser state. Duplicate keys, extended JSON5 tokens, comments, and external reasoning tags use the complete repair path when needed. Whole-report materialization is proportional to the output size. `RepairStream::with_uncached_policy` provides a same-policy full-prefix reference for differential tests and benchmarks.

```moonbit
///|
test "preview while the model is streaming" {
  let stream = @json_repair.RepairStream::new()
  guard stream.push(
      (
        #|{"args":{"city":"Sing
      ),
    )
    is Ok(_) else {
    fail("chunk was rejected")
  }
  guard stream.preview() is Ok(preview) else { fail("preview was rejected") }
  assert_eq(
    preview.json,
    (
      #|{"args":{"city":"Sing"}}
    ),
  )
  guard stream.push(
      (
        #|apore"}}
      ),
    )
    is Ok(_) else {
    fail("chunk was rejected")
  }
  guard stream.preview() is Ok(completed) else { fail("result was rejected") }
  assert_eq(
    completed.json,
    (
      #|{"args":{"city":"Singapore"}}
    ),
  )
  assert_true(completed.edits.is_empty())
}
```

### Extraction and reasoning

`extract_all` scans prose and fenced blocks for separate documents. Its results include source spans and structural confidence. Opt into reasoning isolation with `with_ignore_think_blocks(true)` and pass the policy to repair, extraction, or streaming. ASCII case-insensitive tags inside JSON strings remain literal. An unclosed reasoning block is isolated through end of input, and its audited ranges use original source coordinates.

```moonbit
///|
test "extract two payloads and preserve a JSON5 integer" {
  let options : @json_repair.RepairOptions = {
    ..@json_repair.RepairOptions::default(),
    json5: true,
  }
  let reply = "First {id:0x20000000000001}\nThen [.5]"
  let blocks = @json_repair.extract_all(reply, options).unwrap()
  assert_eq(blocks.length(), 2)
  assert_eq(blocks[0].report.json, "{\"id\":9007199254740993}")
  assert_eq(blocks[1].report.json, "[0.5]")
}

///|
test "coerce a numeric argument and request a precise retry" {
  let input : Json = { "amount": "42.5", "currency": "BTC" }
  let schema : Json = {
    "properties": {
      "amount": { "type": "number", "minimum": 0 },
      "currency": { "enum": ["USD", "SGD"] },
    },
  }
  let healed = @json_repair.coerce_with_schema(input, schema)
  assert_eq(healed.edits.length(), 1)
  assert_eq(healed.errors[0].path, "$.currency")
  let prompt = @json_repair.format_retry_prompt(healed.value, schema)
  assert_true(prompt.contains("$.currency"))
}
```

```moonbit
///|
test "ignore reasoning drafts before extracting a tool call" {
  let policy = @json_repair.RepairOptions::default().with_ignore_think_blocks(
    true,
  )
  let reply = "<THINK>{amount:99</THINK>\n{amount:2"
  let blocks = @json_repair.extract_all_with_policy(reply, policy).unwrap()
  assert_eq(blocks.length(), 1)
  assert_eq(blocks[0].report.json, "{\"amount\":2}")
  assert_eq(blocks[0].report.edits[0].action, "ignore think block")
}
```

### Live patches

`next_patches` compares against the last successful snapshot, starting at JSON `null`. Failed previews leave that baseline in place. The returned `fields` mark syntax closed in the source prefix. Synthetic delimiters added by repair can leave a field open. Pointer tokens escape `~` as `~0` and `/` as `~1`. Array alignment is bounded. A replacement for a growing string includes the entire current value. [RFC 6901](https://www.rfc-editor.org/rfc/rfc6901) · [RFC 6902](https://www.rfc-editor.org/rfc/rfc6902)

```moonbit
///|
test "apply patches as a tool field seals" {
  let stream = @json_repair.RepairStream::new()
  stream.push("{\"args\":{\"order/id\":\"SG").unwrap()
  let first = stream.next_patches().unwrap()
  assert_true(
    first.fields.any(field => {
      field.pointer == "/args/order~1id" && !field.is_sealed
    }),
  )
  stream.push("D\"}}").unwrap()
  let next = stream.next_patches().unwrap()
  assert_eq(next.patches[0].path, "/args/order~1id")
  let updated = @json_repair.apply_json_patches(
    first.report.value,
    next.patches[:],
  ).unwrap()
  assert_eq(updated.stringify(), next.report.json)
  assert_true(
    next.fields.any(field => {
      field.pointer == "/args/order~1id" && field.is_sealed
    }),
  )
}
```

### Source diagnostics and semantic recovery

Use `render_diagnostic` with a repair failure, a single edit, or a Schema validation error. Use `render_repair_audit` for the full edit list. Repair diagnostics underline the original input. Schema diagnostics point into the JSON text representing the validated value. The output includes source lines, a bounded display window, and a suggestion. Plain text is the default. Set `ansi=true` in an ANSI-capable terminal.

Semantic recovery is opt-in through `coerce_with_schema_semantic`. Use it after syntactic repair and before invoking a tool. Check the resulting validation errors before forwarding the payload. Candidate keys must be unoccupied and unambiguous. Enum normalization requires a unique canonical value. Successful changes retain decimal number lexemes and carry exact audit paths.

```moonbit
///|
test "inspect semantic repair before invoking a tool" {
  let input =
    #|{"userName":"Ada","currency":"usd"}
  let schema : Json = {
    "type": "object",
    "required": ["user_name", "currency"],
    "properties": {
      "user_name": { "type": "string" },
      "currency": { "enum": ["USD", "EUR"] },
    },
  }
  let repaired = @json_repair.repair(input).unwrap()
  let recovered = @json_repair.coerce_with_schema_semantic(
    repaired.value,
    schema,
  )
  assert_true(@json_repair.validate(recovered.value, schema).is_empty())
  let errors = @json_repair.validate(repaired.value, schema)
  let rendered = @json_repair.render_diagnostic(
    input,
    @json_repair.SourceDiagnostic::Schema(errors[0]),
  )
  assert_true(rendered.contains("^"))
}
```

### MCP guard

Register an exact tool name with its argument schema and pass incoming JSON-RPC 2.0 frames to `guard_mcp_tool_call`. The guard can repair the envelope and stringified `params.arguments`. Enable `coerce` to opt into schema-guided conversions. Route an accepted frame to the server and a locally generated error to the requester. Keep the wire string to preserve the original spelling of numeric request IDs and arguments.

```moonbit
///|
test "guard a tool call and preserve exact decimal text" {
  let schemas : Json = {
    "sum": {
      "type": "object",
      "required": ["x"],
      "properties": { "x": { "type": "integer" } },
    },
  }
  let routes = @json_repair.ToolSchemaRegistry::from_json(schemas).unwrap()
  let source =
    #|{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"sum","arguments":{"x":"9007199254740993"}}}
  let result = @json_repair.guard_mcp_tool_call(source, routes, coerce=true)
  assert_true(result.forward)
  let frame = result.frame.unwrap()
  assert_true(frame.contains("\"id\":9007199254740993"))
  assert_true(frame.contains("\"x\":9007199254740993"))
}
```

Invalid parameters, unknown tools, and argument validation failures can produce `-32602` with precise paths and retry guidance in `error.data`. Unrepairable syntax returns `-32700` and an invalid envelope returns `-32600`. A rejected notification without an ID has no response. The application supplies tool authorization and execution. [JSON-RPC 2.0](https://www.jsonrpc.org/specification) · [MCP Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

## Integration examples

| Example | What to run |
| --- | --- |
| [01 · MoonBit agent gateway](https://github.com/ZSY2221/moon_json_repair/tree/main/examples/01-moonbit-agent-gateway) | A standalone consumer isolates `<think>`, repairs JSON, coerces an argument, and prints a retry for a remaining schema violation. |
| [02 · JS/TS Wasm GC SDK](https://github.com/ZSY2221/moon_json_repair/tree/main/examples/02-ts-wasm-gc-sdk) | Consume RFC 6902 frames through the standalone SDK while preserving wide integers. |
| [03 · MCP guard pipeline](https://github.com/ZSY2221/moon_json_repair/tree/main/examples/03-mcp-guard-pipeline) | Pipe sample JSON-RPC traffic through the Native CLI to see pass-through, repaired arguments, and `-32602` for a rejected amount. |

Run the pipeline from the repository root.

```sh
moon run --target native cmd/main -- --mcp-guard --tool-schemas examples/03-mcp-guard-pipeline/tools.json --coerce examples/03-mcp-guard-pipeline/requests.ndjson
```

The repository contains the examples, the playground, and their verification scripts. The Mooncakes archive contains the library, command sources, and consumer documentation.

## Native CLI

Use a C toolchain for the Native target. Invoke the built executable directly when an integration needs the exact exit code.

```sh
moon run --target native cmd/main -- ./tool-output.txt
moon run --target native cmd/main -- --schema ./tool-schema.json --coerce --retry-prompt ./tool-output.txt
moon run --target native cmd/main -- --schema ./tool-schema.json --diagnostic-format pretty ./tool-output.txt
moon run --target native cmd/main -- --ndjson --strict-exit --ignore-think ./calls.ndjson
```

| Flag | Behavior |
| --- | --- |
| `--ndjson` | Process one physical UTF-8 line at a time and continue after failed records. |
| `--json5` | Opt into hexadecimal integers and extended decimal forms. |
| `--ignore-think` | Isolate reasoning before repair or extraction. |
| `--extract-all` | Emit separate candidates with source spans and confidence. |
| `--coerce` | Apply supported conversions with a document schema or MCP tool registry. |
| `--diagnostic-format pretty` | Write the plain source view to stderr and retain structured JSON on stdout in document and NDJSON modes. Use `ansi` for terminal color. |
| `--strict-exit` | Return process status for record-level failures in batch modes. |

### SSE gateway

```sh
moon run --target native cmd/main -- --sse --emit-patches --ignore-think --strict-exit -
```

The gateway maintains independent streams for Chat Completions tool-call argument deltas and Messages `input_json_delta` blocks. The output `event` distinguishes `patch`, `tool_call`, and `error`. The consumer can track a baseline per provider, message, choice, and tool or content-block index. [SSE framing](https://html.spec.whatwg.org/multipage/server-sent-events.html)

### MCP stdio

```sh
moon run --target native cmd/main -- --mcp-guard --tool-schemas ./tools.json --coerce --strict-exit -
```

Give the CLI one frame per physical UTF-8 line. Valid non-tool frames pass through, and rejected tool frames produce available JSON-RPC errors. Split these outputs by direction in the host application. In strict mode, malformed input takes precedence with status `1`, then argument or schema rejection with `3`, otherwise success `0`. Command-usage errors return `2`.

## Interactive workbench

Open `web/index.html` from a checkout or use the deployed copy. The language switch updates the workbench in place. A valid `?lang=zh` or `?lang=en` takes priority, followed by the stored preference and then the browser locale. The scenarios group stream recovery, MCP, the 50 KB incremental benchmark, and exact integers with coercion. Input budgets keep large or deeply nested pastes and escape-heavy inputs bounded.

Choose JS or Wasm GC when both are available. The 50 KB scenario compares cached and full-prefix processing at the same chunk width and checks snapshot equality before displaying the latency curves. The separate 10,000-attempt tool compares repair engines on a fixed truncated fixture. Copy the current options as MoonBit or a Native CLI PowerShell script. [Open the English workbench](https://zsy2221.github.io/moon_json_repair/?lang=en)

```sh
node web/build.mjs
node tools/playground-engine-smoke.mjs
```

Open the Live UI Duel to watch Wasm GC isolate a streamed reasoning draft and render fields from incomplete JSON. The strict lane starts at the known JSON boundary in the fixture and first renders when the payload closes. The Chaos Arena runs seeded inputs in short batches and reports measured throughput and runtime failures.

## Repair contract

- Compact JSON retains valid escape spellings, field order, and decimal lexemes. Use `report.json` for lossless transport, especially through JavaScript.
- Audit offsets are zero-based. Lines and columns are one-based. Offsets and columns count UTF-16 code units, and `end_offset` is exclusive. CRLF counts as one newline.
- Duplicate keys, competing roots, incomplete numbers, and raw lone UTF-16 surrogates produce typed errors. A final member without a value can be dropped and audited. The library defaults cap input at 1,048,576 UTF-16 units, nesting at 128, and edits at 16,384. The workbench sets its own input budget.
- The JSON Schema subset supports boolean schemas, type unions, and selected object, array, number, and string constraints. Unsupported validation keywords produce schema-definition errors. Use `format_retry_prompt` to generate bounded feedback for remaining errors.

## Verification

Wasm GC and JS passed **802/802** tests per backend with warnings denied. Coverage reached **2,671/2,680** Wasm GC core points, including **342/342** for the incremental repair parser.

```sh
moon info
moon fmt --check
for target in wasm-gc js native; do
  moon check --target "$target" --deny-warn
  moon test --target "$target" --deny-warn
  node tools/verify-readme.mjs . "$target"
done
moon doc
node tools/core-coverage.mjs
node tools/verify-examples.mjs wasm-gc
node tools/verify-examples.mjs js
node tools/verify-examples.mjs native
node tools/verify-examples.mjs --browser
node packages/json-repair-wasm/build.mjs
node --test packages/json-repair-wasm/index.test.mjs
node examples/02-ts-wasm-gc-sdk/main.mts
```

The Native commands need a working C compiler. Browser asset checks use Node 24. The fixed corpus contains 248 RFC 8259 fixtures, including 93 valid inputs accepted with zero edits, plus 44 constructed model-output failure cases. [Corpus and fixtures](https://github.com/ZSY2221/moon_json_repair/tree/main/corpus)

## Benchmarks

Run `node tools/bench-ecosystem.mjs` to compare strict parsing, JS, and the Wasm GC SDK on this host without network access. Add `--native` on Linux or `--native-wsl OpenAtom-Validation-2204-20261120` on Windows. Pass `--compare-npm <module-path>` to include a locally installed repair package over the same inputs and timing scope.

The v0.5.0 release benchmark streams a 50 KB serialized `write_file` frame in 64 UTF-16-unit chunks. It checks snapshot equality before timing. Each ratio compares full-prefix and cached processing within one backend, before bridge serialization and UI rendering.

| 50 KB / 64 units | JS reference → cached | Wasm GC reference → cached |
| --- | --- | --- |
| `preview` | 231.93 → 0.92 ms · 251.99× | 142.47 → 11.99 ms · 11.88× |
| `next_patches` | 233.44 → 1.44 ms · 162.11× | 146.46 → 11.39 ms · 12.86× |

Ecosystem results were measured on the same Windows host using Node 24.20.0. Of the 292 fixtures, 217 have an expected recoverable output. The 50 KB run uses 196 chunks of up to 256 UTF-16 units.

| Engine | Exact outputs | Exact numbers | µs/fixture | 50 KB output frames | gzip -9 B |
| --- | ---: | ---: | ---: | ---: | ---: |
| JSON.parse | 63/217 | 2/18 | 3.65 | 1/196 | — |
| JS | 217/217 | 18/18 | 9.61 | 196/196 | 127,675 |
| Wasm GC SDK | 217/217 | 18/18 | 19.38 | 196/196 | 90,604 |

The strict parser produces an output when a prefix is valid. JS serializes Patch frames. The SDK also decodes the lossless representation. The full Wasm GC engine is 201,031 B, and the JS bundle is 937,867 B. Native and optional npm comparisons require runs on the target host.

```sh
node tools/release-bench.mjs
node tools/wasm-size.mjs --baseline 4e121f8
node tools/eval-corpus.mjs --sdk
node tools/bench-ecosystem.mjs
```

[Changelog](https://github.com/ZSY2221/moon_json_repair/blob/main/docs/CHANGELOG.md) · [Release checklist](https://github.com/ZSY2221/moon_json_repair/blob/main/docs/PUBLISH_CHECKLIST.md) · [Apache-2.0](LICENSE)
