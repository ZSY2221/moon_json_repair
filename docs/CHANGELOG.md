# 更新记录 / Changelog

## 0.5.0

- 新增源码行号、UTF-16 感知标注、修复建议和彩色终端输出。 / Render repair and Schema diagnostics with source lines, UTF-16-aware carets, suggestions, and optional ANSI color.
- 显式启用 Schema 语义自愈。键名与枚举只采纳可确定的匹配，并保留变更审计。 / Opt into audited semantic recovery for unambiguous keys and enum values.
- 新增独立 JS/TS Wasm GC SDK，支持修复、提取、流式补丁和 MCP。 / Add a standalone JS/TS Wasm GC SDK for batch repair, extraction, stream patches, and MCP.
- 演练台新增无刷新中英切换、实时界面对决与固定种子混沌压测。 / Switch the workbench language in place, compare live stream renderers, and profile deterministic edge cases.
- 为超长输入、深层嵌套和密集转义设置前端预算。 / Bound long pastes, deep nesting, and escape-heavy inputs before invoking a browser engine.
- 用独立 MoonBit 网关、JS/TS SDK 和 MCP 管道示例覆盖三种接入方式，纳入 CI。 / Exercise the independent MoonBit gateway, JS/TS SDK, and MCP pipeline in CI.

- Wasm GC 和 JS 各通过 908 项。核心覆盖率 3,233/3,243（99.69%）。新增 512 条固定种子语义回归，核心累计 7,264 条。 / Wasm GC and JS each pass 908 tests. Core coverage is 3,233/3,243 (99.69%), with 512 new seeded semantic cases and 7,264 seeded core cases overall.

## 0.4.0

- 流式预览复用可证明安全的解析检查点，保留原有报告和审计语义。 / Reuse safe parsing checkpoints for streaming previews and preserve report and audit semantics.
- 通过 MoonBit API 或 `--mcp-guard` 按工具名校验 MCP JSON-RPC 请求，保留请求 ID 的原始十进制。 / Validate MCP tool requests by name through the MoonBit API or `--mcp-guard` while preserving decimal request IDs.
- 演练台新增 50 KB 流式延迟实测曲线、MCP 放行与拒绝案例，以及 MoonBit 和 PowerShell 代码复制。 / Add a measured 50 KB latency plot, MCP allow and reject examples, and copyable MoonBit and PowerShell snippets.
- 增补公开 API 文档和可执行的 MCP 示例。 / Document the public API and add an executable MCP example.
- Wasm GC 与 JS 各通过 790 项，含新增 1,152 条固定种子差分输入，Wasm GC 核心覆盖 2,668/2,680。 / Both Wasm GC and JS passed 790 tests, with 1,152 added seeded differential inputs and 2,668/2,680 Wasm GC core coverage points.

## 0.3.0

- 推理标签检查点保留嵌套草稿中待决的单双引号恢复。 / Incremental reasoning checkpoints preserve overlapping recovery decisions for nested quoted drafts.
- 增加 RFC 6902 增删改、RFC 6901 指针和字段封口状态。 / Add JSON Patch add, remove and replace operations and source-based field seals.
- Native CLI 解析两种供应商的 SSE 工具调用分片，支持逐行 Patch 与严格退出码。 / Stream provider tool-call deltas through the Native CLI with patches and final exit status.
- 浏览器同时运行 JS 与 Wasm GC，引擎可切换，实验台显示 Patch 和字段进度。 / Run both offline browser engines with live patch and field views.
- 以固定 JSONTestSuite 版本扩充 RFC 8259 用例，并验证分片和 Patch 回放。 / Pin external RFC 8259 fixtures and exercise seeded patch replay.
- Wasm GC、JS 各 694 项通过，5,600 个固定种子样本，Wasm GC 核心覆盖 2,147/2,157（99.54%）。 / 694 tests on each locally verified backend, 5,600 seeded inputs and 2,147/2,157 covered core points.

## 0.2.0

- 新增多块提取、绝对 UTF-16 审计范围和结构评分 / Multi-call extraction with absolute audit spans and structural confidence.
- 增量检查点和终态封存 / Incremental lexical checkpoints and finalization.
- 可选 JSON5 数字、精确 Schema 自愈与紧凑重试提示 / Opt-in JSON5 numbers, exact schema coercion, and compact retry prompts.
- 实验室新增可控流式回放、双栏高亮、无损报告和万次浏览器基准 / Lab playback controls, paired highlights, lossless reports, and browser benchmarking.
- 减少词法位置快照分配，分片内批量扫描普通字符串内容 / Reduce position snapshot allocations and scan ordinary streaming string units in runs.
- 切换提取结果复用本次修复，Pages 从选定提交构建引擎 / Reuse repair output when switching blocks and rebuild the Pages engine from the selected commit.
- 增加可选 `RepairPolicy` 推理块隔离，保留旧 API。单块、提取和流式入口共享原文审计坐标。 / Add opt-in `<think>` filtering with source audits across batch, extraction and streaming APIs.
- Native CLI 支持 NDJSON、错误续跑、严格退出码、多块提取和 Schema 纠错。 / Add Native NDJSON pipelines, strict exit status, extraction and schema correction.
- 演练台新增推理草稿预设与隔离开关，CI 验证 34 条固定语料和 Native 实际管道。 / Add the reasoning preset and verify the 34-case corpus and Native pipes in CI.
- 每后端 382 项通过。2,400 个固定种子样本，Wasm GC 核心覆盖 1,655/1,682（98.4%）。 / 382 tests per backend, 2,400 seeded inputs and 1,655/1,682 Wasm GC coverage points (98.4%).

## 0.1.0

- 容错 JSON 词法和解析器 / Tolerant JSON lexer and parser.
- 可定位的修复日志与流式补全接口 / Source-located repair events and a streaming completion API.
- 支持工具调用参数的 Schema 子集 / Schema subset for tool-call arguments.
- 跨后端边界测试、快照测试与幂等性测试 / Cross-backend boundary, snapshot, and idempotency tests.
- 文件与标准输入 CLI、浏览器演练台和双语文档 / File and stdin CLI, browser playground, and bilingual documentation.
- 发布包白名单、子路径资源预检、独立消费者示例和六类样本基准 / Release allowlist, Pages asset checks, independent consumer tests, and six-case benchmarks.

## 开发里程碑 / Development milestones

| 里程碑 | 范围 |
| --- | --- |
| `feat: init lexer & AST` | 初始化 MoonBit 模块、许可证与 AST，完成词法基础。 |
| `feat: implement LLM JSON repair engine & audit trace` | 实现容错解析、日志定位和流式补全。 |
| `feat: add Agent tool-call schema validator` | 实现 Schema 子集语义和字段路径错误。 |
| `test: add 80+ edge-case & idempotency tests` | 加入严格 JSON、畸形输入、审计快照、Schema 和幂等性覆盖。 |
| `feat: add CLI & JS/Wasm interactive playground + bilingual docs` | 完成命令行、页面、发布指引和复现资料。 |

初始版本把五个里程碑落实为 10 个有独立内容的提交，分别覆盖模块与公共类型、容错解析、流式接口、Schema、修复测试、Schema 测试、基准、CLI、演练台和发布文档与工作流。赛务还要求公开持续开发记录。申请前核对公开仓库的实际提交、Issues、PR 和进展记录。 [官方申报表](https://bxup9uklfcb.feishu.cn/share/base/form/shrcnWUMlgpbwHaXgzV7HmNhNhg)
