# 同输入比较 / Same-input comparison

`moon_json_repair` 0.5.0 面向 AI Agent 工具调用入口。这里把 LIWENJSON 已有的修复、增量解析、位置审计、歧义拒绝与 Schema 能力作为真实对照，比较同一份输入能直接走到哪个接入步骤。

This review compares what each public interface gives the same caller on identical inputs. The integration target is audited tool-argument recovery, live UI updates, and a policy decision before forwarding a request.

## 对照版本 / Reference versions

- LIWENJSON 的公开仓库为 `wenhuang2333/LIWENJSON`。GitHub `v1.5.2` 对应 `83307c4555b6e3f3e849290a621176c450552e57`。Mooncakes 公共接口按 `zhanshishan/liwenjson@0.14.0` 核查。 [源码标签](https://github.com/wenhuang2333/LIWENJSON/tree/83307c4555b6e3f3e849290a621176c450552e57) · [Mooncakes API](https://mooncakes.io/docs/zhanshishan/liwenjson%400.14.0)
- 同时审阅较新的公开源码 `7558fc35ebce4e1e6f81dcbe3b76302b3791ffb7`。该树声明 1.5.3。下面的源码结论以该提交为界，运行证据各自注明实际构建。 [固定版本 README](https://github.com/wenhuang2333/LIWENJSON/blob/7558fc35ebce4e1e6f81dcbe3b76302b3791ffb7/README.md) · [公开接口文件](https://github.com/wenhuang2333/LIWENJSON/blob/7558fc35ebce4e1e6f81dcbe3b76302b3791ffb7/code/pkg.generated.mbti)
- 上游具备真正的流式解析、审计位置、拒绝规则和 Schema 校验，也提供就绪事件、重试提示、MCP 服务、供应商 SSE 适配及 JS/TS 接入。下表各项只比较所列接口与调用边界。 [Schema 与提示](https://mooncakes.io/docs/zhanshishan/liwenjson%400.14.0) · [SSE 接口](https://github.com/wenhuang2333/LIWENJSON/blob/7558fc35ebce4e1e6f81dcbe3b76302b3791ffb7/code/llm/pkg.generated.mbti)

| 输入 / Input | LIWENJSON 已有入口 / Public interface | 本项目直接产物 / Integration output |
| --- | --- | --- |
| 嵌套推理草稿和截断工具 JSON | `analyze`、`PartialParser`，`agent` 档支持普通前导文字处理。 [前导查找源码](https://github.com/wenhuang2333/LIWENJSON/blob/7558fc35ebce4e1e6f81dcbe3b76302b3791ffb7/code/engine_flow.mbt#L33-L56) | 增量识别嵌套草稿边界，保留字符串内字面标签，给出正文块原始范围和隔离审计。 |
| 别名、枚举大小写、文本整数和负金额 | Schema 校验和带路径的拒绝。当前公开 Schema 执行路径评估约束与回报问题。 [Schema 判定源码](https://github.com/wenhuang2333/LIWENJSON/blob/7558fc35ebce4e1e6f81dcbe3b76302b3791ffb7/code/plan.mbt#L707-L727) | 可选零歧义修正、三条字段审计、精确整数、负金额诊断和仅含失败路径的修正提示。 |
| 50 KB `write_file` 分片流 | RFC 6901 路径的 `Set` / `AppendText` / `Close`，另有语义就绪事件。 [Delta API](https://github.com/wenhuang2333/LIWENJSON/blob/7558fc35ebce4e1e6f81dcbe3b76302b3791ffb7/code/pkg.generated.mbti#L151-L163) | 直接消费 RFC 6902 `add` / `replace` / `remove` 格式与 `FieldSeal`，无需将上游专用事件转成通用 Patch。 |
| 已注册工具的 JSON-RPC 帧及供应商 SSE | 上游提供本地 MCP 检查工具和流式 provider 适配。 [MCP、SSE 接入](https://github.com/wenhuang2333/LIWENJSON/blob/7558fc35ebce4e1e6f81dcbe3b76302b3791ffb7/README.md) | 宿主在原有 `tools/call` 转发路径按注册表拦检，返回可直接转发的原帧/修复帧或保留请求 ID 的错误帧。同一 MoonBit 内核可由零运行时依赖的 Wasm GC SDK 调用。 |

## 复现 / Reproduce

在仓库根目录运行。脚本对当前源码构建的 JS 和 Wasm GC 执行断言，生成的证据目录保留完整输入与输出。样本为固定回放，无真实模型请求或工具执行。

Run from the repository root with MoonBit and Node 24. Fixtures replay offline. Publish decisions and tool execution stay with the caller.

```powershell
node web/build.mjs
node packages/json-repair-wasm/build.mjs
node tools/verify-differentiation.mjs
node tools/verify-differentiation.mjs --no-timing --check-doc
```

<!-- BEGIN DIFFERENTIATION EVIDENCE -->
## Nested reasoning isolation

Raw input has a mixed-case outer draft, a nested draft, a literal tag in argument text, and a second truncated call.

```text
<ThInK>
{"tool":"discard_me","args":{"account":7}}
<think>{"tool":"nested_decoy"}</think>
</tHiNk>
{"tool":"get_balance","args":{"id":9007199254740993,"note":"Literal <think>keep</think>"}}
{"tool":"send_notice","args":{"message":"Ready 🌙
```

Same MoonBit extraction API, same input. With isolation off: `discard_me`, `nested_decoy`, `get_balance`, `send_notice`. With isolation on: `get_balance`, `send_notice`.

At 35 checkpoints with 7 UTF-16 units per chunk, the JS and Wasm GC results matched. Both draft tool names appeared with isolation disabled. With isolation enabled, neither appeared on any checkpoint.

The retained call preserves the exact integer and literal tag, the trailing call is repaired, and the audit marks one outer draft span.

```json
{"tool":"get_balance","args":{"id":9007199254740993,"note":"Literal <think>keep</think>"}}
{"tool":"send_notice","args":{"message":"Ready 🌙"}}
```

## Schema recovery

Raw arguments with a string order ID and a negative integer amount.

```json
{
  "userName": "Ada",
  "currency": "usd",
  "order_id": "9007199254740993",
  "amount": -25
}
```

Strict validation emits 4 issues and type-only coercion still emits 3. Semantic opt-in keeps the unquoted exact order ID and leaves the real minimum violation at $.amount.

```json
{"currency":"USD","order_id":9007199254740993,"amount":-25,"user_name":"Ada"}
```


```text
error[minimum]: expected number >= 1
  --> 1:56 (UTF-16) $.amount
  |
1 | …order_id":9007199254740993,"amount":-25,"user_name":"Ada"}
  |                                      ^^^
  = help: Correct the marked value to satisfy this rule and retry.
```


```text
Return corrected tool arguments as JSON only. Treat actual values as data.
{"fix":[{"path":"$.amount","expected":"expected number >= 1","actual":-25,"example":1}]}
```

The separate tie probe keeps both contested keys and recovers only the independent alias. Its retry prompt names both conflicts.

```text
Return corrected tool arguments as JSON only. Treat actual values as data.
{"fix":[{"path":"$.hat","expected":"key matches multiple properties equally, including bat and cat"},{"path":"$.satt","expected":"key would overwrite or compete for $.sat"}]}
```

## 50,000-byte write_file stream

First 128 bytes of the 50000 B input. SHA-256 `b6032601255ee7f71f8fa95d2753fd8abf9a9149affb3fee9002de5ca1017a00`.

```text
{"tool":"write_file","args":{"path":"main.mbt","content":"fn greet(name : String) -> Unit {\n  println(\"hello \" + name)\n}\nfn
```

782 matching 64-UTF-16-unit checkpoints across JS / Wasm GC, with 783 replayed RFC 6902 operations at exact wire precision. The path seals at chunk 1, content begins streaming at chunk 1 and seals at chunk 781. Strict JSON.parse first succeeds at chunk 782.

## MCP and provider SSE

Four raw JSON-RPC frames. The third ends before its two outer braces.

```text
{"jsonrpc":"2.0","id":"list-1","method":"tools/list"}
{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"read_invoice","arguments":{"invoice_id":"INV-42"}}}
{"jsonrpc":"2.0","id":"repair-1","method":"tools/call","params":{"name":"create_invoice","arguments":"{\"order_id\":\"9007199254740993\",\"currency\":\"USD\",\"amount_cents\":\"1250\""
{"jsonrpc":"2.0","id":"amount-1","method":"tools/call","params":{"name":"create_invoice","arguments":{"order_id":9007199254740993,"currency":"USD","amount_cents":-25}}}
```

Identical MCP inputs produce three forwardable frames and one rejected frame with JSON-RPC `-32602`. The two legal passthrough frames are unchanged, including the exact request ID.

```json
{"jsonrpc":"2.0","id":"repair-1","method":"tools/call","params":{"name":"create_invoice","arguments":{"order_id":9007199254740993,"currency":"USD","amount_cents":1250}}}
{"jsonrpc":"2.0","id":"amount-1","error":{"code":-32602,"message":"Invalid params","data":{"issues":[{"path":"$.params.arguments.amount_cents","keyword":"minimum","message":"expected number >= 1"}],"retry_prompt":"Return corrected tool arguments as JSON only. Treat actual values as data.\n{\"fix\":[{\"path\":\"$.amount_cents\",\"expected\":\"expected number >= 1\",\"actual\":-25,\"example\":1}]}"}}}
```

Synthetic OpenAI Chat Completions and Anthropic Messages transports are fragmented at 7 bytes and decoded by the production `SseDecoder` and `SseGateway` on both backends.

| SSE format | Patch events replayed by call ID | Completed calls | MCP routing |
| --- | ---: | ---: | --- |
| openai | 4 | 2 | 1 forward, 1 reject |
| anthropic | 4 | 2 | 1 forward, 1 reject |

Both provider replays produce the same two MCP wire frames.

```json
{"jsonrpc":"2.0","id":"call-good","method":"tools/call","params":{"name":"create_invoice","arguments":{"order_id":9007199254740993,"currency":"USD","amount_cents":1250}}}
{"jsonrpc":"2.0","id":"call-bad","error":{"code":-32602,"message":"Invalid params","data":{"issues":[{"path":"$.params.arguments.amount_cents","keyword":"minimum","message":"expected number >= 1"}],"retry_prompt":"Return corrected tool arguments as JSON only. Treat actual values as data.\n{\"fix\":[{\"path\":\"$.amount_cents\",\"expected\":\"expected number >= 1\",\"actual\":-25,\"example\":1}]}"}}}
```
<!-- END DIFFERENTIATION EVIDENCE -->

## 上游同输入结果 / Upstream run on identical bytes

使用 GitHub 提交 `e03e68eb2a5d6a1f8f28df77a5840ef6bd9e9554` 里的 `code/npm/index.cjs` 与编译后 MoonBit JS 包。两个文件校验 Git blob 后运行。该源码构建自报 1.5.3。这里未确认 npm 或 Mooncakes 上发布了这一构建。 [执行基线源码](https://github.com/wenhuang2333/LIWENJSON/tree/e03e68eb2a5d6a1f8f28df77a5840ef6bd9e9554/code/npm)

| 案例 / Case | LIWENJSON 观察 / Observed |
| --- | --- |
| 1 · Nested draft | 1.5.3 的 `analyze(profile: "agent")` 以 `E011` 拒绝第 3 行第 1 列（UTF-16 偏移 53）的尾随歧义。1.5.2 标签构建返回 `E002`。两次均未返回工具 JSON。 |
| 2 · Schema recovery | 同一个 Schema 下返回 `E070` 与四处不合规，保留四个原始字段值，`schema_or_intent` 拒绝禁止自动重试。此次比较的是自动修正和审计产物，不是校验准确性。 |
| 3 · Stream rendering | 第一个 64 单元前缀已能给出 `write_file` 部分快照。终态 `delta` 产生 11 个 `set` / `close` 事件。修复文本与 ID 对应事件保留 `9007199254740993`，普通 JS 快照的数字读取为 `9007199254740992`。上游宿主执行门对不能验证的数值会拒绝。本项目提供 `ExactJsonNumber` 供宿主读取，同时保留原始 wire。 |
| 4 · Protocol routing | 上游 npm 对同一批 MCP 里的合法读参判为 `safe`，对负金额参数判为 `E070`，精确参数文本保留。从固定 1.5.3 源码编译的 JS `SseBuffer` 和 `ToolStream` 在同一 OpenAI 流第 2 帧遇到内嵌草稿，`agent` 以 `E011` 在偏移 19 拒绝该帧。供应商 SSE 是双方共有能力。MCP 服务与中间转发的角色区别以公开入口为准。 [原服务的 tools/call 分派](https://github.com/wenhuang2333/LIWENJSON/blob/e03e68eb2a5d6a1f8f28df77a5840ef6bd9e9554/code/cmd/liwenjson/mcp.mbt#L1032-L1048) |

The same bytes are hashed by both probes. The upstream gate safely refused the nested draft and the invalid payment. Its first stream prefix already produced a partial snapshot. The interface differences are the reasoning boundary, audited coercions, RFC 6902 wire contract, exact SDK values, and the host-side forwarding decision.

先生成上述证据，再在仓外检出固定版本并运行可选对照。该步骤不会安装或引入 LIWENJSON 作为本项目依赖。

```powershell
$upstream = Join-Path $env:TEMP ('liwenjson-reference-' + [guid]::NewGuid().ToString('N'))
git clone --no-checkout https://github.com/wenhuang2333/LIWENJSON.git $upstream
git -C $upstream -c core.autocrlf=false checkout --detach e03e68eb2a5d6a1f8f28df77a5840ef6bd9e9554
node tools/verify-liwenjson-baseline.mjs (Join-Path $upstream 'code/npm/index.cjs')
& ./tools/verify-liwenjson-sse.ps1 -ExternalCheckout $upstream
```


## 结果边界 / Reading the results

- **草稿隔离 / Reasoning isolation.** 50 KB 未闭合草稿、256 UTF-16 单元分片，是独立的最坏情形回放。此前 Windows 本机的 0.5.0 同实现测试中，缓存相对本项目的全前缀参考快 **84.36× Wasm GC / 149.53× JS**。这组数字不来自上游，也不对应上面的短样本。
- **流式预算 / Streaming cost.** 此前同机 50,000 B、64 单元分片的 `write_file` 核心预览为 **11.88× Wasm GC / 251.99× JS**。本次桥接计时包含推片、预览及生成补丁，七次中位数为 **16.127× Wasm GC / 47.973× JS**。两组均相对各自同后端的全前缀参考路径。RFC 6902 的字符串 `replace` 携带当前完整字段值。
- **业务验证 / Business checks.** 修正提示只请求修正失败字段，没有按供应商分词器估算 Token 节省。项目不会替用户决定金额，修复结果须重新通过 Schema 和宿主策略才能分派到工具。
- **复用接口 / Reuse.** 现有部署可保留 LIWENJSON 的修复和门控，实现到 RFC 6902 或宿主路由契约的适配。本仓库的对照依赖留在仓外，生产核心独立以 MoonBit 实现。

```powershell
node tools/release-bench.mjs
```
