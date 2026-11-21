# 更新记录 / Changelog

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
