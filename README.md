# moon_json_repair

纯 MoonBit 的 LLM 工具调用 JSON 修复与校验引擎。流式响应可以在任意位置截断，模型也可能混入 Markdown、注释或 Python 字面量。引擎把当前输入修复成严格 JSON，返回原文位置可核对的审计记录，再按工具参数 Schema 校验。

A pure MoonBit engine for repairing and validating LLM tool-call JSON. Use it when a streaming response stops mid-value, or the model mixes JSON with Markdown, comments, or Python literals. Each repair returns strict JSON, its AST, and source-located edits. A separate validation step checks the tool arguments.

[快速开始 / Quick start](#快速开始--quick-start) · [CLI](#cli) · [演练台 / Playground](#演练台--playground) · [基准 / Benchmarks](#基准--benchmarks) · [发布清单 / Release checklist](docs/PUBLISH_CHECKLIST.md)

## 能力 / Features

| 能力 | Behavior |
| --- | --- |
| 容错修复 | Unwraps fenced JSON and prose around a structured root. Repairs missing or trailing commas, identifier keys, apostrophe strings, Python/JS literals, comments, and raw controls in strings. |
| 流式预览 | Closes incomplete strings, arrays, and objects and completes recognizable literal prefixes. Appends chunks to a bounded buffer and can preview it at any time. |
| 结构化审计 | Reports each repair with a machine-readable kind, action, original UTF-16 coordinates, and replacement. Preserves exact numeric lexemes. |
| 参数 Schema | Supports `type` (including integer and unions), `required`, `properties`, `enum`, `minimum`, `maximum`, `minLength`, `maxLength`, and `items`. Reports exact field paths. |
| 跨后端 | Shared library targets Wasm GC, JS, and Native. Uses the MoonBit standard library with zero external modules and zero project FFI. |

## 快速开始 / Quick start

项目使用 MoonBit 0.1.20261119 验证。安装官方工具链后，可在仓库根目录先运行 `moon test`。模块发布后，在消费方模块中执行以下命令。

The project was verified with MoonBit 0.1.20261119. After installing the [official toolchain](https://www.moonbitlang.com/download/), run `moon test` from this checkout. Once the module is published, add it to a consuming module with the following command.

```sh
moon add ZSY2221/json_repair
```

在调用包的 `moon.pkg` 中添加导入。 Add this import to the consuming package.

```moonbit
import {
  "ZSY2221/json_repair" @json_repair,
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

Feed chunks to `RepairStream::push` and call `preview()` for a provisional result. A preview reparses the accumulated prefix. Revalidate the final buffer before dispatching a tool call.

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

## 修复约定 / Repair contract

- `RepairReport.json` 是紧凑 JSON，保留合法字符串转义、对象字段顺序和数字原始拼写。`value` 是 MoonBit 标准库 `Json` AST 的公共别名。`edits` 按发现顺序记录，格式化空白没有审计条目。

  `RepairReport.json` is compact JSON and retains valid escape spellings, field order, and numeric text. `value` uses MoonBit's `Json` AST. Edits are reported in discovery order. Formatting whitespace does not produce an event.
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
```

标准输出是一份 JSON 报告，包含 `json`、`value`、`edits`、`schema`。提供 Schema 时，`schema` 含 `valid` 和 `errors`。`0` 表示修复及可选校验成功，`3` 表示修复成功且 Schema 校验失败。I/O、修复和用法错误以 JSON 写到标准错误，分别使用 `1`（运行错误）和 `2`（用法错误）。构建后的 CLI 可直接运行，保留相同的参数与退出码。

Stdout is one JSON report with `json`, `value`, `edits`, and `schema`. With a schema, the last field contains `valid` and `errors`. Exit status `0` indicates success and `3` indicates a repaired document that failed schema validation. Runtime and usage errors are JSON on stderr with status `1` and `2` respectively. Run the built executable directly to retain those exact process exit codes.

## 演练台 / Playground

打开 [web/index.html](web/index.html) 即可离线使用。内置六例，支持实时修复、前缀回放、审计点击定位和可编辑 Schema。浏览器只加载本地文件。

Open [web/index.html](web/index.html) directly in a browser. Six examples demonstrate live repair, prefix playback, audit-to-source navigation, and editable schemas. The browser needs only the checked-in local assets.

![演练台在浏览器中运行 / Playground repairing a truncated tool call](web/screenshot.png)

`web/engine.js` 由 `cmd/playground` 通过 MoonBit JS 后端编译。以下脚本将编译产物复制到离线页面。发布到 GitHub Pages 的步骤见[发布清单](docs/PUBLISH_CHECKLIST.md#2-推送-github-并部署-pages)。

`web/engine.js` is generated from `cmd/playground` using the MoonBit JS backend. Rebuild it with the following command. GitHub Pages deployment is covered in the [release checklist](docs/PUBLISH_CHECKLIST.md#2-推送-github-并部署-pages).

```sh
node web/build.mjs
```

## 验证 / Verification

```sh
moon fmt --check
moon check --deny-warn
moon test
moon test --target js
moon test --target native
moon doc
```

三后端各通过 160 项测试。Wasm GC 构建的核心包覆盖率为 852/918 个插桩点（92.8%）。

All 160 tests passed on each backend. The Wasm GC build covered 852 of 918 instrumentation points in the library (92.8%).

## 基准 / Benchmarks

Windows、AMD Ryzen 9 8945HX、Node.js 24.20.0，MoonBit 0.1.20261119 的 JS release 构建。表中是每次操作的平均时间及标准差，来自十组测量。

Windows, AMD Ryzen 9 8945HX, Node.js 24.20.0, MoonBit 0.1.20261119 JS release build. Times are mean and standard deviation per operation across ten measurement groups.

| 工作负载 / Workload | 输入 UTF-16 单元 / Input units | 平均时间 / Mean ± SD |
| --- | ---: | ---: |
| 100 个严格 JSON 工具调用 / Strict 100-call array | 8,401 | 402.45 ± 29.41 µs |
| 100 个混合畸形工具调用 / Damaged 100-call array | 8,811 | 490.14 ± 19.96 µs |
| 单次截断修复和 Schema 校验 / Truncated call + schema | 60 | 9.01 ± 0.21 µs |

```sh
moon bench --target js --release --no-parallelize
```

[变更记录 / Changelog](docs/CHANGELOG.md) · [Apache-2.0](LICENSE)
