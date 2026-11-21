# moon_json_repair

[![CI](https://github.com/ZSY2221/moon_json_repair/actions/workflows/ci.yml/badge.svg)](https://github.com/ZSY2221/moon_json_repair/actions/workflows/ci.yml) [![Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-4059ad)](LICENSE) ![Targets: Wasm GC, JS, Native](https://img.shields.io/badge/targets-Wasm%20GC%20%7C%20JS%20%7C%20Native-684dc2)

![演练台修复截断的工具调用 / Playground repairing a truncated tool call](https://raw.githubusercontent.com/ZSY2221/moon_json_repair/main/web/screenshot.png)

按原始位置从混合回复提取独立工具调用。保留精确数字和可追踪修复日志。必要时按 Schema 自愈安全类型偏差，并为业务校验生成最短重试数据。

Extract independent tool calls from mixed replies, preserving exact number text and audit coordinates. Opt into safe schema-guided type fixes and generate bounded retry instructions for remaining errors.

[在线演练台 / Live demo](https://zsy2221.github.io/moon_json_repair/) · [快速开始 / Quick start](#快速开始--quick-start) · [CLI](#cli) · [基准 / Benchmarks](#基准--benchmarks) · [发布清单 / Release checklist](https://github.com/ZSY2221/moon_json_repair/blob/main/docs/PUBLISH_CHECKLIST.md)

本分支准备 Mooncakes `0.3.0`。 / This branch prepares Mooncakes `0.3.0`.

## 能力 / Capability matrix

| 能力 / Capability | 默认行为与扩展 / Behavior and opt-in |
| --- | --- |
| 单块修复 / Single repair | Legacy default policy and API. Fences, comments, missing delimiters, exact decimal spelling and UTF-16 audit positions. |
| 多块提取 / Multi-call extraction | `extract_all` finds non-overlapping candidates in prose and fenced blocks, with absolute spans and a structural confidence score. |
| 推理块隔离 / Reasoning isolation | Opt-in `RepairPolicy` skips `<think>` blocks before repair or extraction, with source-coordinate audits. |
| 流式检查点 / Stream checkpoint | Incremental lexical state from `push` and `status`. `finalize` seals the source and yields the authoritative repair report. |
| Patch 与字段封口 / Patch and seals | `next_patches` emits RFC 6902 add, replace and remove operations and JSON Pointer states from successful previews. |
| SSE 接入 / SSE gateway | Native CLI consumes chat tool-call deltas and message tool-use deltas, optionally emitting patch records. |
| JSON5 数字 / JSON5 numbers | Opt-in hex integers, leading or trailing decimal dots and leading plus. Exact decimal audit, 1,024 hex digit budget. |
| Schema 与自愈 / Schema and coercion | Explicit `coerce_with_schema` converts supported exact string types and separately opted-in single-item arrays. `format_retry_prompt` reports remaining constraint errors. |
| 浏览器实验室 / Browser lab | JS and Wasm GC run offline, with playback, paired audits, Patch and field views, and live 10,000-iteration benchmarking. |
| 平台 / Targets | Wasm GC, JS and Native with zero external MoonBit modules and zero project FFI. |

## 快速开始 / Quick start

项目使用 MoonBit 0.1.20261119 验证。安装官方工具链后，可在仓库根目录先运行 `moon test`。模块发布后，在消费方模块中执行以下命令。

The project was verified with MoonBit 0.1.20261119. After installing the [official toolchain](https://www.moonbitlang.com/download/), run `moon test` from this checkout. Once the module is published, add it to a consuming module with the following command.

```sh
moon add ZSY2221/json_repair
```

在消费方的 `moon.pkg` 添加测试导入，再把下面的示例粘贴到 `readme_test.mbt` 中，运行 `moon test --deny-warn`。在普通 `.mbt` 源文件中调用时，使用常规导入块。

Add the test import to the consumer's `moon.pkg`, paste the examples into `readme_test.mbt`, and run `moon test --deny-warn`. For production `.mbt` files, use a regular import block.

```moonbit
import {
  "ZSY2221/json_repair" @json_repair,
} for "test"
```

五行验证修复与 Schema 规则。 Five lines to check repair and schema validation.

```moonbit
test "five-line tool call repair" {
  let report = @json_repair.repair("{amount:42").unwrap()
  let schema : Json = { "required": ["amount"] }
  assert_true(@json_repair.validate(report.value, schema).is_empty())
}
```

以下示例修复截断的工具调用，再校验金额和货币。 This example repairs a truncated tool call and checks its amount and currency.

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

把模型的每个 chunk 交给 `RepairStream::push`，用 `preview()` 读取当前前缀的临时结果，直到传输结束。预览会重新解析当前缓冲区，单次耗时随前缀长度变化。

Feed chunks to `RepairStream::push` and observe open delimiters and the last balanced position through `status()`. A preview reparses the accumulated prefix. Call `finalize()` on end of input, validate the final report, and reset the stream before reuse.

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

## 批量提取与纠错 / Extraction and retries

扩展能力在对应入口显式开启。低置信度表示结构或修复证据较弱。每个调用仍应独立完成 Schema 校验和执行授权。

Opt in through the dedicated APIs. Lower confidence marks weaker structural evidence. Validate and authorize each tool call independently.

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

## 推理块隔离 / Reasoning isolation

`RepairOptions` 的字段与旧入口保持兼容。用 `with_ignore_think_blocks(true)` 创建 `RepairPolicy`，传给 `repair_with_policy`、`extract_all_with_policy` 或 `RepairStream::with_policy`。策略默认关闭。标签按 ASCII 大小写匹配，参与修复的 JSON 字符串保留标签文字。未闭合推理块隔离至输入末尾。跳过的范围通过 `ignore_think_block` 审计码定位到原始 UTF-16 坐标。有审计报告时，每处范围只归属一个结果。全为推理内容时，单块返回 `empty_input`，多块返回空列表。

The `RepairOptions` fields and legacy entry points stay source-compatible. Create a `RepairPolicy` with `with_ignore_think_blocks(true)` for `repair_with_policy`, `extract_all_with_policy`, or `RepairStream::with_policy`. Tags are ASCII case-insensitive. JSON strings retain literal tags, and a reasoning block with no recognized close is hidden through end of input. Each `ignore_think_block` audit span belongs to one result and refers to the original UTF-16 coordinates. Reasoning-only input yields `empty_input` for single repair or an empty extraction list.

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

推理隔离开启时，`push` 增量识别跨分片标签，`status` 读取检查点。`preview`、`next_patches` 和 `finalize` 提供完整 JSON 时仍会解析缓冲区。`finalize()` 与相同策略的一次性修复一致。

如果草稿自身的引号未闭合，只有独占一行且后续引号边界明确异常的关闭标签才结束隔离。嵌套草稿的单双引号各有独立的待决判定。同种引号共享一次向前判定，所有增量候选最多保留四条路径，每条还有至多一个等待换行的备选。边界仍有歧义时，草稿继续隔离。

The reasoning matcher advances with `push` and exposes a checkpoint via `status`. Full previews, patches and final reports still parse the buffered text. `finalize()` matches one-shot repair with the same policy. A closing tag inside an unfinished draft string requires its own line and an invalid quote boundary. The two quote kinds track their decisions independently. Same-kind markers share lookahead, with at most four lexical paths and one tentative standalone marker per path.

## 实时 Patch 与字段封口 / Live patches and field seals

`next_patches()` 对比本会话上一次成功快照，首次从 JSON `null` 开始。失败快照不推进前态。`reset()` 清除状态。Patch 指针包含 RFC 6901 的 `~0` 和 `~1` 转义。字段封口表示本次源前缀已经提供了真实的语法结束信号。补出的闭括号、未结束的字符串与仍可能增长的数字保持 streaming。 [RFC 6901](https://www.rfc-editor.org/rfc/rfc6901) · [RFC 6902](https://www.rfc-editor.org/rfc/rfc6902)

对数组，先去掉两端相同元素。两段差异长度均大于 1 且乘积至多为 4,096 时进行有界编辑对齐，其余按位置生成操作。大数组的操作数可能超过最少步数。

`next_patches()` compares with the last successful snapshot, starting from JSON `null`. Failed previews do not advance the baseline. Each pointer uses RFC 6901 escaping. Array middles use edit alignment when both lengths exceed one and their product is at most 4,096. Larger middles use positional edits, which can produce a longer patch. A seal describes the syntax present in this source prefix. Tool execution still requires final validation and authorization.

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

## 修复约定 / Repair contract

- `RepairReport.json` 是紧凑 JSON，保留合法字符串转义、对象字段顺序和数字原始拼写。`value` 是 MoonBit 标准库 `Json` AST 的公共别名。推理隔离的审计按原文位置合并，格式化空白没有审计条目。

  `RepairReport.json` is compact JSON and retains valid escape spellings, field order, and numeric text. `value` uses MoonBit's `Json` AST. The reasoning policy merges its edits in source order. Formatting whitespace does not produce an event.
- 审计 `position.offset` 从 0 开始，`line` 和 `column` 从 1 开始。偏移和列按 UTF-16 代码单元计数，`end_offset` 不包含端点，CRLF 算一个换行。

  The offset is zero-based. Line and column are one-based. Offsets and columns count UTF-16 code units. `end_offset` is exclusive, and CRLF counts as one newline.
- EOF 处没有值的末尾对象字段会被移除并记录。未知、截断和未配对的转义会保留为文本。重复键、第二个 JSON 根、不完整的数字词元和输入中的未配对 UTF-16 代码单元返回类型化错误。默认输入上限为 1,048,576 个 UTF-16 代码单元，嵌套深度 128，审计条目 16,384，可通过 `RepairLimits` 调整。

  A final member without a value is dropped and audited. Unknown, cut-off, and unpaired escapes are retained as text. Duplicate keys, competing JSON roots, incomplete number tokens, and raw lone UTF-16 surrogates return typed errors. Defaults are 1,048,576 UTF-16 input units, 128 levels, and 16,384 edits. Use `RepairLimits` to tune them.
- Schema 支持布尔规则和类型联合，字符串长度按 Unicode 码点计算。定义错误以 `$schema` 开头，实例错误以 `$` 开头，例如 `$.args.amount`。当前约束集以功能表为准，未知校验关键字会产生定义错误。

  Boolean schemas and type unions are supported. String lengths count Unicode code points. Definition paths start at `$schema` and instance paths at `$`. Unsupported validation keywords produce definition errors.

## CLI

原生 CLI 读取 UTF-8 文件或标准输入。Linux 需要可用的 C 编译器。Windows 可使用 WSL，在上面的三个库后端中，Native 通过 Ubuntu 22.04 验证。

The native CLI reads a UTF-8 file or stdin. Use an environment with a C compiler. Native verification was run on Ubuntu 22.04 under WSL.

```sh
moon run --target native cmd/main -- ./tool-output.txt
moon run --target native cmd/main -- --schema ./tool-schema.json ./tool-output.txt
printf '%s' "{tool:'quote',args:{amount:12.50" | moon run --target native cmd/main -- -
moon run --target native cmd/main -- --ndjson --strict-exit --ignore-think ./calls.ndjson
moon run --target native cmd/main -- --extract-all --ignore-think --schema ./tool-schema.json --coerce --retry-prompt -
```

标准输出是一份 JSON 报告，包含 `json`、`value`、`edits`、`schema`。提供 Schema 时，`schema` 含 `valid` 和 `errors`。`0` 表示修复及可选校验成功，`3` 表示修复成功且 Schema 校验失败。I/O、修复和用法错误以 JSON 写到标准错误，分别使用 `1`（运行错误）和 `2`（用法错误）。构建后的 CLI 可直接运行，保留相同的参数与退出码。

Stdout is one JSON report with `json`, `value`, `edits`, and `schema`. With a schema, the last field contains `valid` and `errors`. Exit status `0` indicates success and `3` indicates a repaired document that failed schema validation. Runtime and usage errors are JSON on stderr with status `1` and `2` respectively. Run the built executable directly to retain those exact process exit codes.

| 参数 / Flag | 作用 / Behavior |
| --- | --- |
| `--ndjson` | Emit one JSON report per physical UTF-8 line, with 1-based `line`, `ok`, and `status`. Consume failed lines and continue. |
| `--ignore-think` | Skip reasoning ranges before repair or extraction. |
| `--extract-all` | Return `blocks` including `start`, `end`, `confidence`, and each block's repair fields. |
| `--coerce` / `--retry-prompt` | Require `--schema`. Add `coercions` or a `retry_prompt` for constraints that still fail. |
| `--strict-exit` | In NDJSON mode, return `1` for rejected lines, otherwise `3` for schema violations, otherwise `0`. |

NDJSON 默认整批返回 `0` 并通过行状态报告局部错误。用法或全局 I/O、Schema 读取失败仍返回进程错误。\
NDJSON normally exits `0` after emitting individual line failures. Usage, I/O, and invalid schema-file JSON still affect the process exit status.

### SSE 网关 / SSE gateway

```sh
moon run --target native cmd/main -- --sse --emit-patches --ignore-think --strict-exit -
moon run --target native cmd/main -- --sse --schema ./arguments.schema.json ./capture.sse
```

每个供应商调用使用独立流。Chat Completions 风格读取 `choices[].delta.tool_calls[].function.arguments`，Messages 风格读取 `input_json_delta.partial_json`。两种格式的独立推理字段均不进入参数修复器。输出为 NDJSON，`event` 区分 `patch`、`tool_call` 与 `error`。仅最终校验参与严格退出码汇总。 [SSE 帧格式](https://html.spec.whatwg.org/multipage/server-sent-events.html) · [Chat Completions 流事件](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events) · [Messages 流事件](https://platform.claude.com/docs/en/build-with-claude/streaming)

The gateway keeps separate tool streams by choice and tool index or content block index. `--emit-patches` streams patch and field records before the final `tool_call`. `--strict-exit` gives final parse or transport failures precedence (1), then final schema failures (3), then success (0). Input comes from stdin or a captured SSE file.

消费者可按 `(provider, message_id, choice_index, index)` 维护各自的 Patch 基线。`seq` 在单个调用内从 1 开始。`--coerce` 使用展示值计算 Patch，封口态仍反映原始参数文本。`[DONE]` 和 `message_stop` 可主动结束管道，未派发的尾部事件按协议边界报错。

## 演练台 / Playground

从源码仓库打开 `web/index.html` 即可离线使用。内置六个基础样本和扩展示例。流式播放支持 30 / 60 / 120 tok/s、暂停、单步和重放，速率指演练台模拟分片而非模型 tokenizer。审计支持双栏定位，下载保留 MoonBit 原始报告字节。[源码仓库](https://github.com/ZSY2221/moon_json_repair)

Open `web/index.html` directly from a repository checkout. Both engines work offline in browsers with Wasm GC and native JS string builtins. The JS engine remains available when Wasm GC is unsupported. Try the reasoning preset, patch log, streaming and sealed parameter cards, and the 10,000-iteration comparison on one fixture.

`web/engine.js` 由 `cmd/playground` 通过 MoonBit JS 后端编译。以下脚本将编译产物复制到离线页面。[GitHub Pages 发布清单](https://github.com/ZSY2221/moon_json_repair/blob/main/docs/PUBLISH_CHECKLIST.md#2-推送-github-并部署-pages)

`web/engine.js` and the offline Wasm GC byte carrier are generated from `cmd/playground`. Rebuild both with the following command. [GitHub Pages deployment checklist](https://github.com/ZSY2221/moon_json_repair/blob/main/docs/PUBLISH_CHECKLIST.md#2-推送-github-并部署-pages)

```sh
node web/build.mjs
```

Pages 工作流会从选定提交重新构建引擎，再上传 `web/` 的静态文件。The Pages workflow rebuilds the engine from the selected commit before uploading the static files.

## 验证 / Verification

```sh
moon fmt --check
for target in wasm-gc js native; do
  moon check --target "$target" --deny-warn
  moon test --target "$target" --deny-warn
  node tools/verify-readme.mjs . "$target"
done
moon doc
node tools/cli-smoke.mjs
node tools/core-coverage.mjs
```

本次修复的 Wasm GC、JS 各通过 **694/694** 项测试。源码和归档的独立消费模块各运行 7 条 README 测试。**5,600** 个固定种子样本包含新增的 400 个嵌套引号恢复用例，检查分片状态、精确 Patch 回放和幂等性。Wasm GC 核心覆盖 **2,147/2,157（99.54%）**。修复前的 `588bff8` 在 Native 上通过 691 项单测和 14 项 CLI 进程场景，修复后的 Native 复测待 CI。

Wasm GC and JS each passed **694/694** tests and seven independent README consumer tests from both source and the release archive. The **5,600** seeded inputs include 400 nested quote-recovery cases checking chunk checkpoints, exact patch replay and idempotence. Wasm GC core coverage is **2,147/2,157 (99.54%)**. Native passed 691 tests and 14 process scenarios at `588bff8` before the fix. Native CI is pending for the fixed source.

## 基准 / Benchmarks

### RFC 8259 与模型故障语料 / Conformance and tool-call corpus

采用固定版本 JSONTestSuite 和 RFC 控制字符用例。93 个合法样本仅移除格式化空白，审计为零。两条上游重复键样本归为互操作保护用例。44 条工具调用故障样本由人工构造，覆盖分片、推理草稿、精确数字和 Schema。 [语料与许可](corpus/README.md) · [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259)

The corpus pins JSONTestSuite and adds raw-control cases from RFC 8259. Duplicate-key cases are tracked as policy rejections. The 44 synthetic model-output fixtures contain no provider transcripts. [Fixture methodology](corpus/README.md)

| 对照 / Comparison | `JSON.parse` | MoonBit Wasm GC | MoonBit JS | MoonBit Native |
| --- | ---: | ---: | ---: | ---: |
| RFC 合法样本接受 / Accepted valid RFC cases | 93/93 | 93/93 | 93/93 | 93/93 |
| RFC 合法样本原文保真、零审计 / Exact valid output and zero edits | — | 93/93 | 93/93 | 93/93 |
| RFC 可恢复项精确输出 / Exact RFC output | 56/181 | 181/181 | 181/181 | 181/181 |
| RFC 保护拒绝 / RFC policy rejections | 64/67 | 67/67 | 67/67 | 67/67 |
| 工具调用精确恢复 / Exact tool-call recovery | 7/36 | 36/36 | 36/36 | 36/36 |
| 工具调用保护拒绝 / Tool-call policy rejections | 5/8 | 8/8 | 8/8 | 8/8 |
| 精度用例原文匹配 / Exact precision cases | 2/18 | 18/18 | 18/18 | 18/18 |
| Schema 路径、约束与自愈 / Exact Schema outcomes | — | 8/8 | 8/8 | 8/8 |
| 混合语料 / Mixed-corpus µs per input · MB/s | 3.85 · 4.31 | 5.73 · 2.90 | 8.83 · 1.88 | 12.51 · 1.33 |
| 运行产物 / Runner artifact gzip -9 bytes | — | 71,377 | 98,824 | 346,124 |

精确匹配比较紧凑输出，包含数字原文。严格基线用 `JSON.parse` 后再序列化，拒绝率按异常计。MoonBit 路径生成含审计的报告，保护拒绝还核对错误类型。混合语料耗时和 Gzip 行保留 `588bff8` 的同批三后端基准。修复后的 JS 和 Wasm GC 再次通过 292 条结果断言，最新引擎体积见浏览器一节。

Exact comparisons include numeric lexemes. The baseline parses and serializes, and counts throws as rejection. MoonBit checks the precise rejection kind. The mixed timings and gzip sizes preserve the matched three-target run at `588bff8`. The rebuilt JS and Wasm GC both passed the 292 fixture assertions.

```sh
node web/build.mjs
node tools/eval-corpus.mjs --native
```

Windows 用 `node tools/eval-corpus.mjs --native-wsl DISTRO`。交叉语料评测需要 Node 24，Mooncakes 库本身按三目标独立编译。

### 100 KB 热路径前后 / 100 KB hot path

同机复跑 Git `150ccff` 与修复前的 v0.3.0 候选 `588bff8`，Ryzen 9 8945HX、MoonBit `0.1.20261119`、Node `24.20.0`、Ubuntu 22.04.5 WSL。固定负载为重复标准键、十进制工具参数及截断尾部。基准记录 10 组 release 均值。

| 后端 / Target | 150ccff ms / MB/s | 0.3.0 ms / MB/s | 吞吐量变化 / Throughput |
| --- | ---: | ---: | ---: |
| Wasm GC | 3.62 / 27.62 | 3.17 / 31.55 | +14.2% |
| JS | 18.35 / 5.45 | 16.04 / 6.23 | +14.3% |
| Native (WSL) | 3.05 / 32.79 | 2.51 / 39.84 | +21.5% |

普通双引号键直接取已解码原文，保留含转义键的严格解码与重复检查。字符串和数字按无换行区段更新游标，调整审计位置时仍保留原始 UTF-16 行列。在该负载上，单份报告仍使用标准库完整解析以生成 AST。

Plain quoted keys bypass a second strict parser invocation. Escaped keys still decode before duplicate detection. Strings and digits advance the cursor in flat runs, preserving UTF-16 coordinates and exact decimal spellings. The finished JSON still passes through the strict parser for its AST.

同一 100 KB 载荷的隔离消融另测一轮。Wasm GC 当前、恢复逐键解析、再恢复逐单位游标分别为 3.12、3.40、3.44 ms。Native 当前两次复测为 2.66、2.68 ms，逐键解析为 2.76 ms，两项均恢复时为 2.88 和 3.57 ms。Native 波动较大，单项贡献以对照方向为准。

On the isolated 100 KB ablation, Wasm GC measured 3.12 ms with both changes, 3.40 ms with key re-parsing restored, and 3.44 ms when per-unit cursor updates were also restored. Native timings varied between runs. The controlled variants support the direction of the optimization.

| 输入 / Input | Wasm GC µs / MB/s | JS µs / MB/s | Native µs / MB/s |
| --- | ---: | ---: | ---: |
| 200 B | 5.30 / 37.74 | 23.27 / 8.59 | 4.53 / 44.15 |
| 2,000 B | 56.60 / 35.34 | 291.30 / 6.87 | 47.13 / 42.44 |
| 20,000 B | 599.63 / 33.35 | 3,020.00 / 6.62 | 487.64 / 41.01 |
| 100,000 B | 3,170.00 / 31.55 | 16,040.00 / 6.23 | 2,510.00 / 39.84 |

### 推理检查点 / Reasoning checkpoints

在 1,024 B 同一输入上，每个分片写入后读取状态。下表保留 `588bff8` 同批三后端基准，每格为 v0.2 重扫路径与该版检查点的均值（µs）。比较先断言流终态和一次性修复的 JSON、审计逐字一致。

| 分片 UTF-16 | Wasm GC µs | JS µs | Native µs |
| ---: | ---: | ---: | ---: |
| 16 | 475.49 → 16.83 · 28.25× | 1,050.00 → 17.57 · 59.76× | 482.70 → 14.17 · 34.06× |
| 64 | 137.59 → 17.97 · 7.66× | 275.81 → 17.08 · 16.15× | 126.23 → 11.41 · 11.06× |
| 256 | 38.79 → 17.23 · 2.25× | 81.91 → 16.67 · 4.91× | 36.71 → 10.75 · 3.41× |
| 50,000 B 未闭合，256 单元分片 | 72,980 → 741.59 · 98.41× | 136,950 → 643.37 · 212.86× | 64,470 → 451.84 · 142.68× |

修复后单独重跑 256 单元分片的未闭合样本。Wasm GC 从 5 KB 的 62.95 µs 增至 50 KB 的 768.39 µs，JS 从 77.94 µs 增至 787.03 µs。同轮 50 KB 的 v0.2 参考路径分别为 66.24 ms 和 124.28 ms。每个输入单元仅送入检查点一次，读状态不重扫前缀。完整预览和 Patch 会重解析当前前缀。

With the fix, the unclosed 5 KB to 50 KB run at 256 units per chunk grew from 62.95 to 768.39 µs in Wasm GC and from 77.94 to 787.03 µs in JS. The same run's 50 KB v0.2 rescans took 66.24 ms and 124.28 ms. The matcher consumes each source unit once. Full previews still parse the current prefix, and framing state stays bounded by the depth limit.

```sh
node tools/release-bench.mjs
```

Windows 可传 `--native-wsl DISTRO` 指定已安装 MoonBit 和 C 工具链的 WSL。基准还输出默认策略的逐片预览与单次终态对比，以及同一小输入的原始／Gzip 探针体积。

### 浏览器双引擎 / Browser dual-engine probe

`588bff8` 的 Edge 157 验收在 Pages 子路径模拟环境加载 7 个本地资源，HTTP 和控制台错误均为零。下表保留该轮测量。Wasm GC 使用官方 JS 字符串内建函数选项，离线 HTML 使用编码在本地脚本中的 Wasm 字节。 [MoonBit JS 字符串内建函数](https://www.moonbitlang.com/blog/js-string-builtins)

| 固定截断样本（各 10,000 次） / Fixed truncated example | 修复率 | 中位 µs | MB/s |
| --- | ---: | ---: | ---: |
| MoonBit Wasm GC | 100% | 4.80 | 23.76 |
| MoonBit JS | 100% | 6.80 | 17.96 |
| `JSON.parse` | 0% | 2.80 | 45.45 |

修复后的原始 Wasm GC 为 156,735 B（Gzip 71,942 B），JS 为 718,056 B（Gzip 99,738 B）。当前环境中 Edge 在启动阶段退出，修复版的 browser E2E 待复测。

[变更记录 / Changelog](https://github.com/ZSY2221/moon_json_repair/blob/main/docs/CHANGELOG.md) · [Apache-2.0](LICENSE)
