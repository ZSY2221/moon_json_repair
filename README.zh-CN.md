# moon_json_repair

[English README](README.md) · [同输入对照](docs/DIFFERENTIATION.md) · [在线双语演练台](https://zsy2221.github.io/moon_json_repair/?lang=zh) · [Mooncakes 0.5.0 文档](https://mooncakes.io/docs/ZSY2221/json_repair%400.5.0) · [JS/TS Wasm GC SDK](https://github.com/ZSY2221/moon_json_repair/tree/main/packages/json-repair-wasm) · [![CI](https://github.com/ZSY2221/moon_json_repair/actions/workflows/ci.yml/badge.svg)](https://github.com/ZSY2221/moon_json_repair/actions/workflows/ci.yml)

修复模型流和工具调用中的截断 JSON，保留 `9007199254740993` 等数字的原始拼写。修复操作可追溯到原输入的 UTF-16 位置。支持 RFC 6902 实时补丁、字段闭合状态，以及工具参数的 Schema 校验与可选类型自愈。库由纯 MoonBit 实现，支持 **Wasm GC、JS、Native**，零外部 MoonBit 模块，零项目 FFI。

**0.5.0** 新增源码诊断、显式启用的 Schema 语义自愈、零运行时依赖的 Wasm GC SDK，以及离线双语演练台。实时对决展示工具参数尚未传完时哪些字段已经能渲染。混沌压测分开统计修复成功、保护性拒绝与运行异常。

| 本地验证 | 实测结果 |
| --- | --- |
| Wasm GC / JS | 各通过 **908 项测试** · Wasm GC 核心覆盖率 **99.69%** |
| 测试语料 | **248** 条 RFC 8259 · **44** 条构造模型故障 · **7,264** 条固定种子核心样本 |
| 50 KB 流式、64 UTF-16 单元 | 缓存预览相对同后端全前缀参考，**JS 加速 251.99 倍**，**Wasm GC 加速 11.88 倍** |
| Wasm GC SDK | Node 24 **12 项**全过，精确十进制 JSON，引擎 gzip **90,604 B** |
| 双语混沌竞技场 | Node 中 **1,152** 条 JS/Wasm GC 结果一致 · 0 桥接异常 |

## 快速选入口

| 场景 | 入口 | 输出 |
| --- | --- | --- |
| 单条模型 JSON 截断 | [`repair`](#快速开始) | 紧凑 JSON、AST、修复审计 |
| 工具参数仍在流入 | [`RepairStream::next_patches`](#实时补丁) | RFC 6902 操作、字段闭合状态 |
| 回复中有正文、代码围栏或推理草稿 | [`extract_all_with_policy`](#提取与推理隔离) | 独立 JSON 文档、源范围 |
| 供应商通过 SSE 输出工具参数 | [`--sse --emit-patches`](#sse-网关) | 按调用划分的 NDJSON 补丁与终态 |
| MCP 工具调用参数检查 | [`guard_mcp_tool_call`](#mcp-防火墙) 或 `--mcp-guard` | 放行帧或 JSON-RPC 错误响应 |

## 快速开始

安装官方 MoonBit 工具链。0.5.0 在注册表可用后，在消费方模块目录中执行以下命令。 [MoonBit 工具链](https://www.moonbitlang.com/download/)

```sh
moon add ZSY2221/json_repair@0.5.0
```

在消费方的 `moon.pkg` 中加入测试导入，然后把下面的代码放进 `readme_test.mbt`。业务源码使用常规导入块。

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

### 流式预览

每收到一片，用 `push` 写入。`preview` 读取当前前缀的完整修复报告，`status` 查询未闭合的位置和层级，`next_patches` 返回补丁和字段闭合状态。传输结束调用 `finalize`，复用同一对象前调用 `reset`。

直接 JSON 续写会复用已提交的解析状态。重复键、JSON5 扩展词元、注释或字符串外的推理标签按需交给完整修复路径。完整报告仍按输出大小物化。需要差分测试或基准对照时，可用 `RepairStream::with_uncached_policy` 在同一策略下重扫全前缀。

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

### 提取与推理隔离

`extract_all` 从正文和围栏内的回复提取独立候选并给出源范围及结构置信度。用 `with_ignore_think_blocks(true)` 显式开启推理隔离，并将策略传入单块修复、提取或流式接口。标签按 ASCII 大小写匹配。JSON 字符串中的字面标签保持原样，未闭合推理块隔离至输入末尾，跳过的范围仍指向原文。

第一个用例从两段文本中保留精确整数。第二个用例先把金额字符串转换为数字，再根据剩余的币种错误生成简短重试提示。

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

### 实时补丁

`next_patches` 比较上一次成功快照，初始基线是 JSON `null`。失败的预览不推进基线。返回的 `fields` 表示字段在本次源前缀中的闭合状态。修复器补出的闭合符不会自动把字段标记为已封口。JSON Pointer 将 `~` 转义为 `~0`，将 `/` 转义为 `~1`。数组对齐的计算量受限。替换仍在增长的字符串时，RFC 6902 补丁携带当前完整值。 [RFC 6901](https://www.rfc-editor.org/rfc/rfc6901) · [RFC 6902](https://www.rfc-editor.org/rfc/rfc6902)

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

### 源码诊断与语义自愈

用 `render_diagnostic` 展示修复失败、单条修改或一次 Schema 校验错误。完整修改列表可交给 `render_repair_audit`。语法诊断标注原始输入，业务诊断指向校验数据对应的 JSON 文本。输出包含源码行、有限长度的上下文窗口及下一步建议。默认使用纯文本，支持 ANSI 的终端可指定 `ansi=true`。

语义自愈通过 `coerce_with_schema_semantic` 显式启用。先修复 JSON 语法，再执行参数自愈，最后根据校验结果决定是否调用工具。键名目标必须唯一且未占用，枚举归一化必须能确定唯一规范值。每笔修改保留精确审计路径，数值沿用原始十进制拼写。

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

### MCP 防火墙

按工具的完整名称注册参数 Schema，然后把 JSON-RPC 2.0 请求帧交给 `guard_mcp_tool_call`。守卫可修复外层 JSON，并解码字符串形式的 `params.arguments`。只有启用 `coerce` 才执行 Schema 指定的安全类型转换。将有效帧发往服务端，将本地错误返回请求方。直接转发输出字符串可保持请求 ID 和数字参数的原始拼写。

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

未知工具或无效参数可生成 `-32602`。`error.data` 携带精确路径和适用的重试提示。无法修复的语法错误返回 `-32700`，无效外层请求返回 `-32600`。被拒绝的无 ID 通知没有响应。工具授权和执行由调用方负责。 [JSON-RPC 2.0](https://www.jsonrpc.org/specification) · [MCP 工具规范](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

## 三套接入示例

| 示例 | 操作与输出 |
| --- | --- |
| [01 · MoonBit Agent 网关](https://github.com/ZSY2221/moon_json_repair/tree/main/examples/01-moonbit-agent-gateway) | 独立 MoonBit 消费方完成推理隔离、截断修复、类型自愈和剩余错误的重试提示。 |
| [02 · JS/TS Wasm GC SDK](https://github.com/ZSY2221/moon_json_repair/tree/main/examples/02-ts-wasm-gc-sdk) | 通过独立 SDK 渐进生成 RFC 6902 补丁，保留超出 JavaScript 安全整数范围的十进制值。 |
| [03 · MCP 防火墙管道](https://github.com/ZSY2221/moon_json_repair/tree/main/examples/03-mcp-guard-pipeline) | 在仓库根目录运行下方命令，观察正常帧透传、残缺参数修复与无效金额的 `-32602` 响应。 |

```sh
moon run --target native cmd/main -- --mcp-guard --tool-schemas examples/03-mcp-guard-pipeline/tools.json --coerce examples/03-mcp-guard-pipeline/requests.ndjson
```

示例、浏览器演练台和验证脚本随 GitHub 仓库分发。Mooncakes 归档包含库与命令源码，以及供独立消费方使用的文档。

## 原生命令行

Native 目标需要 C 工具链。集成测试需要准确的进程退出码时，可直接运行构建后的可执行文件。

```sh
moon run --target native cmd/main -- ./tool-output.txt
moon run --target native cmd/main -- --schema ./tool-schema.json --coerce --retry-prompt ./tool-output.txt
moon run --target native cmd/main -- --schema ./tool-schema.json --diagnostic-format pretty ./tool-output.txt
moon run --target native cmd/main -- --ndjson --strict-exit --ignore-think ./calls.ndjson
```

| 选项 | 语义 |
| --- | --- |
| `--ndjson` | 每个 UTF-8 物理行处理一条输入，单条失败后继续。 |
| `--json5` | 允许十六进制整数及扩展十进制写法。 |
| `--ignore-think` | 在修复与提取前隔离推理内容。 |
| `--extract-all` | 返回候选及各自的范围、结构置信度。 |
| `--coerce` | 按文档 Schema 或 MCP 注册表执行安全类型转换。 |
| `--diagnostic-format pretty` | 在文档和 NDJSON 模式将源码诊断写入 stderr。stdout 保留结构化 JSON。彩色终端可用 `ansi`。 |
| `--strict-exit` | 批处理模式下，把单条失败计入进程退出码。 |

### SSE 网关

```sh
moon run --target native cmd/main -- --sse --emit-patches --ignore-think --strict-exit -
```

网关为 Chat Completions 的工具参数分片和 Messages 的 `input_json_delta` 内容块分别维护流。输出事件类型为 `patch`、`tool_call` 或 `error`。调用方可按供应商、消息、候选和工具或内容块编号维护独立补丁基线。 [SSE 帧格式](https://html.spec.whatwg.org/multipage/server-sent-events.html)

### MCP 管道

注册表文件是严格 JSON，键为工具名，值为参数 Schema。每个 UTF-8 物理行承载一个 JSON-RPC 帧。有效的非工具帧透传，工具失败时输出可关联的 JSON-RPC 错误。宿主负责将放行帧和错误分发到不同方向。严格模式优先报语法与外层错误 `1`，其次报参数或 Schema 拒绝 `3`，成功为 `0`。命令用法错误为 `2`。

## 双语演练台

可以直接从仓库打开 `web/index.html` 离线使用，也可以访问公网部署。支持原地切换中文与英文。有效的 `?lang=zh`、`?lang=en` 优先，然后依次读取本地记忆和浏览器语言。

- **流式急救**。分片回放截断回复，检查原文位置、审计项和字段封口。
- **MCP 防火墙**。比较 JSON-RPC 放行与 `-32602` 错误，保留请求 ID 和问题路径。
- **50 KB 增量压测**。在同一个引擎上对照检查点与全前缀参考路径，逐片确认结果后绘制耗时曲线。
- **大整数与自愈**。查看数字原文的保留方式，以及 Schema 如何发现错误并执行允许的类型转换。

工作台会约束超长输入、深层嵌套和密集转义。支持 Wasm GC 与原生 JS 字符串内建函数的浏览器可切换引擎，其余环境可用 JS 引擎。另有固定截断用例的万次运行对照，并可按当前选项复制 MoonBit 和 Native CLI 的 PowerShell 代码。 [打开中文演练台](https://zsy2221.github.io/moon_json_repair/?lang=zh)

```sh
node web/build.mjs
node tools/playground-engine-smoke.mjs
```

打开「实时界面对决」，查看 Wasm GC 如何从模型流中隔离推理草稿，并在 JSON 闭合前逐个渲染字段。严格解析侧从预设流的 JSON 正文边界开始解析，直到正文闭合才渲染。混沌竞技场分批执行固定种子样本，显示引擎吞吐与异常次数。

## 修复与审计约定

- 紧凑 JSON 保留合法转义、字段顺序和数值词元。跨 JavaScript 边界传输大整数时，使用 `report.json` 原文。
- 审计偏移从 0 开始，行列从 1 开始。偏移和列按 UTF-16 代码单元计数，`end_offset` 不含端点，CRLF 算一个换行。
- 重复键、多个根值、不完整数字和原始孤立 UTF-16 代理项会返回类型化错误。对象末尾缺值的字段可删除并记录。库默认上限为 1,048,576 个 UTF-16 单元、128 层、16,384 条编辑，工作台使用独立预算。
- 当前 Schema 子集支持布尔规则、类型联合和部分对象、数组、数字、字符串约束。未知校验关键字会产生 Schema 定义错误。`format_retry_prompt` 为剩余错误生成有长度约束的反馈。

## 验证

Wasm GC 和 JS 分别以 `--deny-warn` 通过 **802/802** 项。Wasm GC 核心覆盖 **2,671/2,680** 个插桩点，其中增量修复解析器覆盖 **342/342**。

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

Native 命令需要可用的 C 编译器。浏览器产物验证使用 Node 24。固定语料包含 248 条 RFC 8259 样本，其中 93 条合法输入经验证零编辑，另有 44 条构造的模型输出失败场景。 [测试语料和来源](https://github.com/ZSY2221/moon_json_repair/tree/main/corpus)

## 流式基准

运行 `node tools/bench-ecosystem.mjs` 在本机对照严格解析、JS 与 Wasm GC SDK，默认无需联网。Linux 可加 `--native`，Windows 可加 `--native-wsl OpenAtom-Validation-2204-20261120`。如已安装第三方库，可加 `--compare-npm <module-path>`，在同一语料与计时范围中实测。

v0.5.0 的发布基准按 64 个 UTF-16 单元写入 50 KB 序列化 `write_file` 帧。每片计时前验证缓存与全前缀报告、补丁及封口状态一致。比值是同一后端内的耗时比，计时在传输及界面渲染之前。

| 50 KB / 64 单元 | JS 参考 → 检查点 | Wasm GC 参考 → 检查点 |
| --- | --- | --- |
| `preview` | 231.93 → 0.92 ms · 251.99 倍 | 142.47 → 11.99 ms · 11.88 倍 |
| `next_patches` | 233.44 → 1.44 ms · 162.11 倍 | 146.46 → 11.39 ms · 12.86 倍 |

生态评测在同一 Windows 主机、Node 24.20.0 实测。217 条预期可恢复样本来自 292 条固定语料。50 KB 工作负载按 256 个 UTF-16 单元分成 196 片。

| 引擎 | 精确恢复 | 精确数字 | µs/样本 | 50 KB 输出帧 | gzip -9 B |
| --- | ---: | ---: | ---: | ---: | ---: |
| JSON.parse | 63/217 | 2/18 | 3.65 | 1/196 | — |
| JS | 217/217 | 18/18 | 9.61 | 196/196 | 127,675 |
| Wasm GC SDK | 217/217 | 18/18 | 19.38 | 196/196 | 90,604 |

严格解析只在完整前缀输出，JS 生成并序列化补丁，SDK 还解码保真的类型。完整 Wasm GC 引擎为 201,031 B，JS 产物为 937,867 B。Native 与第三方对照需在目标环境实跑。

```sh
node tools/release-bench.mjs
node tools/wasm-size.mjs --baseline 4e121f8
node tools/eval-corpus.mjs --sdk
node tools/bench-ecosystem.mjs
```

[更新记录](https://github.com/ZSY2221/moon_json_repair/blob/main/docs/CHANGELOG.md) · [发布清单](https://github.com/ZSY2221/moon_json_repair/blob/main/docs/PUBLISH_CHECKLIST.md) · [Apache-2.0 许可证](LICENSE)
