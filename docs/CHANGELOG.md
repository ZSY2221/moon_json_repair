# 更新记录 / Changelog

## 0.1.0

- 容错 JSON 词法和解析器 / Tolerant JSON lexer and parser.
- 可定位的修复日志与流式补全接口 / Source-located repair events and a streaming completion API.
- 支持工具调用参数的 Schema 子集 / Schema subset for tool-call arguments.
- 跨后端边界测试、快照测试与幂等性测试 / Cross-backend boundary, snapshot, and idempotency tests.
- 文件与标准输入 CLI、浏览器演练台和双语文档 / File and stdin CLI, browser playground, and bilingual documentation.

## 开发里程碑 / Development milestones

| 里程碑 | 范围 |
| --- | --- |
| `feat: init lexer & AST` | 初始化 MoonBit 模块、许可证与 AST，完成词法基础。 |
| `feat: implement LLM JSON repair engine & audit trace` | 实现容错解析、日志定位和流式补全。 |
| `feat: add Agent tool-call schema validator` | 实现 Schema 子集语义和字段路径错误。 |
| `test: add 80+ edge-case & idempotency tests` | 加入严格 JSON、畸形输入、审计快照、Schema 和幂等性覆盖。 |
| `feat: add CLI & JS/Wasm interactive playground + bilingual docs` | 完成命令行、页面、发布指引和复现资料。 |

初始版本把五个里程碑落实为 10 个有独立内容的提交，分别覆盖模块与公共类型、容错解析、流式接口、Schema、修复测试、Schema 测试、基准、CLI、演练台和发布文档与工作流。赛务还要求公开持续开发记录。申请前核对公开仓库的实际提交、Issues、PR 和进展记录。 [官方申报表](https://bxup9uklfcb.feishu.cn/share/base/form/shrcnWUMlgpbwHaXgzV7HmNhNhg)
