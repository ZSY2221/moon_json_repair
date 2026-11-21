"use strict";

// English is the canonical message catalog. Protocol identifiers are kept as
// wire data and never translated before copying, downloading, or validation.
const labChinese = Object.freeze({
  "LLM Stream Repair Lab · MoonBit": "大模型流式修复工作台 · MoonBit",
  "Moon JSON Repair lab home": "JSON 修复工作台首页",
  "Local engine": "本地引擎",
  "Repair engine": "修复引擎",
  "Interface language": "界面语言",
  "Checking Wasm GC support": "正在检测 Wasm GC 支持",
  "LLM Stream": "大模型流式",
  "Repair Lab": "修复工作台",
  "Replay a tool call token by token, inspect each repair, and retry with feedback from your schema.": "逐片回放工具调用，检查每一步修复，并根据 Schema 反馈重试。",
  "Stream incomplete tool calls through MoonBit, inspect repair and schema edits, and export lossless reports.": "用 MoonBit 流式修复残缺的工具调用，追踪修复与 Schema 校验，导出无损报告。",
  "Workspace capabilities": "核心能力",
  "Current engine · {0}": "当前引擎 · {0}",
  "Wasm GC / JS / Native · zero dependencies": "Wasm GC / JS / Native · 零外部依赖",
  "50 KB incremental benchmark": "50 KB 增量压测",
  "MCP firewall": "MCP 防火墙",
  "Quick demo": "快速体验",
  "Compare 10,000 runs": "对比万次跑分",
  "JSON repair workspace": "JSON 修复工作区",
  "Test inputs": "体验场景",
  "Stream triage": "流式急救",
  "Precision and coercion": "大整数与自愈",
  "Stream cut": "截断的工具调用",
  "Recover a tool call that ends inside a string.": "补全在字符串中途断开的工具调用。",
  "Markdown & prose": "Markdown 与说明文字",
  "Extract the JSON payload from surrounding prose and a code fence.": "从说明文字和 Markdown 代码围栏中恢复 JSON。",
  "Python & JS literals": "Python 与 JS 字面量",
  "Normalize non-JSON literals such as True, None, and undefined.": "将 True、None 和 undefined 等字面量转换为标准 JSON。",
  "Comments": "注释与尾逗号",
  "Remove comments and trailing commas without changing payload values.": "删除注释和尾逗号，保留参数值。",
  "Keys & commas": "键名与分隔符",
  "Repair bare keys, single quotes, missing commas, and line breaks.": "修复裸键名、单引号、遗漏逗号和字符串中的换行。",
  "Schema rejection": "Schema 校验拒绝",
  "Inspect rejected payment arguments and the retry prompt.": "查看不合规的支付参数及其重试提示。",
  "Patch stream": "流式 Patch",
  "Watch RFC 6902 operations and field sealing as the call grows.": "观察工具调用逐片增长时的 RFC 6902 操作和字段封口状态。",
  "Precision & coercion": "大整数与类型自愈",
  "Preserve integers beyond JavaScript precision and coerce argument types by schema.": "精确保留超出 JavaScript 安全范围的整数，按 Schema 修正参数类型。",
  "Multiple calls": "提取多个调用",
  "Locate and repair each JSON tool call in a mixed response.": "在混合文本中分别定位并修复多个 JSON 工具调用。",
  "Reasoning draft + truncated calls": "推理草稿与截断调用",
  "Isolate reasoning while retaining literal tags in argument strings.": "隔离推理草稿，保留参数字符串中的字面标签。",
  "50 KB write_file": "50 KB 写文件",
  "Replay a 50 KB code argument and compare incremental and full-prefix latency.": "回放 50 KB 代码参数，对照增量处理和全前缀重扫的延迟。",
  "MCP tools/call": "MCP 调用放行",
  "Repair and validate a JSON-RPC tool call while preserving its exact ID.": "修复并校验 JSON-RPC 工具调用，精确保留请求 ID。",
  "MCP invalid params": "MCP 参数拦截",
  "Inspect a structured -32602 response and its retry guidance.": "查看结构化 -32602 错误与重试建议。",
  "Simulated token stream": "模拟分片输出",
  "Simulate LLM stream": "模拟大模型流式输出",
  "Step one simulated token": "单步发送一个模拟分片",
  "Step": "单步",
  "Replay stream": "重放流式输出",
  "Replay": "重放",
  "Simulated token speed": "模拟输出速度",
  "{0} tok/s": "{0} 片/秒",
  "Repair options": "修复选项",
  "JSON5 numbers": "JSON5 数字",
  "Schema coercion": "按 Schema 修正类型",
  "Extract calls": "提取工具调用",
  "Ignore <think> reasoning": "隔离 <think> 推理块",
  "MCP guard": "MCP 防火墙",
  "Incremental stream status": "增量流状态",
  "Ready · simulated tokens": "就绪 · 模拟分片",
  "Stream progress": "流式进度",
  "Depth {0} · stack {1}": "深度 {0} · 栈 {1}",
  "Depth {0} · stack {1} · quote {2}": "深度 {0} · 栈 {1} · 引号 {2}",
  "No checkpoint": "暂无检查点",
  "Input finalized": "输入已结束",
  "Stable prefix": "前缀已稳定",
  "Checkpoint @{0}": "检查点位置 {0}",
  "Stopped": "已停止",
  "Finalized": "已结束",
  "Live": "进行中",
  "Paused": "已暂停",
  "{0} · {1}/{2} tokens": "{0} · {1}/{2} 片",
  "Extracted blocks": "提取的调用",
  "Block {0} · {1}% · L{2}–{3}": "调用 {0} · 置信度 {1}% · 第 {2}–{3} 行",
  "No candidate blocks": "没有可提取的调用",
  "Model output": "模型输出",
  "Paste or type a tool call…": "粘贴或输入工具调用…",
  "Editable input": "可编辑输入",
  "UTF-16 positions": "UTF-16 坐标",
  "{0} line · {1} UTF-16 units": "{0} 行 · {1} 个 UTF-16 单元",
  "{0} lines · {1} UTF-16 units": "{0} 行 · {1} 个 UTF-16 单元",
  "Repair output": "修复结果",
  "Repaired JSON": "修复后的 JSON",
  "Live patches": "实时 Patch",
  "Copy JSON": "复制 JSON",
  "Download Lossless Report": "下载无损报告",
  "Tool arguments": "工具参数",
  "Play a stream to inspect open and sealed fields.": "播放数据流，查看正在生成和已封口的字段。",
  "RFC 6902 operations": "RFC 6902 操作",
  "Patches will appear as the repaired value changes.": "修复结果变化时，此处显示对应的 Patch。",
  "{0} ops": "{0} 个操作",
  "+ add": "+ 添加",
  "~ replace": "~ 替换",
  "− remove": "− 删除",
  "(root)": "（根节点）",
  "sealed": "已封口",
  "streaming": "生成中",
  "✓ Valid JSON": "✓ 合法 JSON",
  "Unable to repair": "无法修复",
  "Awaiting input": "等待输入",
  "Repair audit": "修复审计",
  "{0} edit": "{0} 处修改",
  "{0} edits": "{0} 处修改",
  "L{0}:C{1}": "第 {0} 行 · 第 {1} 列",
  "Schema": "Schema 约束",
  "Schema validation": "Schema 校验",
  "Edit schema": "编辑 Schema",
  "Leave blank to skip validation": "留空则跳过校验",
  "The input was already valid JSON.": "输入已是合法 JSON，无需修复。",
  "Skipped": "已跳过",
  "Add a schema to validate this block.": "添加 Schema 后可校验此调用。",
  "Invalid schema": "Schema 无效",
  "Fail": "未通过",
  "{0} constraint error": "{0} 条约束未满足",
  "{0} constraint errors": "{0} 条约束未满足",
  "Pass": "已通过",
  "Validated after {0} schema coercion edits.": "按 Schema 修正 {0} 处类型后通过校验。",
  "The repaired value satisfies the current schema.": "修复后的值满足当前 Schema。",
  "Agent Retry Prompt": "智能体重试提示",
  "Copy prompt": "复制提示",
  "Copied": "已复制",
  "Text selected": "已选中文本",
  "JSON-RPC frame": "JSON-RPC 帧",
  "MCP guard decision": "MCP 防火墙判定",
  "Edit tool schema registry": "编辑工具 Schema 注册表",
  "Tool schema registry": "工具 Schema 注册表",
  "Enter a JSON-RPC frame to inspect.": "输入要检查的 JSON-RPC 帧。",
  "Repair counts will appear after the guard runs.": "防火墙处理后显示修复计数。",
  "Pending": "待处理",
  "Provide a tool schema registry for tools/call.": "为 tools/call 提供工具 Schema 注册表。",
  "The guard requires a valid tool schema registry.": "防火墙需要有效的工具 Schema 注册表。",
  "Invalid registry": "注册表无效",
  "No response frame. A rejected notification has no request ID.": "已拒绝无请求 ID 的通知，无需返回响应帧。",
  "{0} envelope edits · {1} argument edits · {2} coercions": "外层修复 {0} 处 · 参数修复 {1} 处 · 类型修正 {2} 处",
  "Forwarded": "已放行",
  "JSON-RPC frame passed through.": "已透传 JSON-RPC 帧。",
  "Blocked {0}": "已拦截 {0}",
  "The guard withheld this request.": "防火墙已拦截此请求。",
  "Cannot load the MoonBit engine. Rebuild it with node web/build.mjs.": "无法加载 MoonBit 引擎。请运行 node web/build.mjs 重建。",
  "Repair output will appear after the engine loads.": "引擎加载后将显示修复结果。",
  "Load the engine to run validation.": "加载引擎后可运行校验。",
  "Repaired JSON will appear here.": "修复后的 JSON 将显示在此处。",
  "Enter tool-call output to see the edits.": "输入工具调用内容后会显示修复记录。",
  "Validation runs as soon as repaired JSON is available.": "得到修复后的 JSON 后自动校验。",
  "{0} · line {1}, column {2}": "{0} · 第 {1} 行，第 {2} 列",
  "The engine is waiting for a repairable prefix or valid input.": "请提供可修复的前缀或合法输入。",
  "Validation needs a repaired JSON value.": "校验需要可用的 JSON 值。",
  "No complete or repairable candidate blocks found.": "未找到完整或可修复的调用。",
  "Paste a response containing a JSON object, array, or fenced block.": "粘贴包含 JSON 对象、数组或代码围栏的响应。",
  "Select an extracted candidate to validate.": "选择提取的调用后即可校验。",
  "Stream paused": "流式输出已暂停",
  "Resume stream": "继续流式输出",
  "Stream ready": "流式输出就绪",
  "Stream input limit reached": "流式输入达到上限",
  "Stream complete": "流式输出已完成",
  "Pause stream": "暂停流式输出",
  "Receiving tokens…": "正在接收分片…",
  "In-browser benchmark": "浏览器性能基准",
  "10,000 attempts per engine · truncated tool call": "每种引擎运行 10,000 次 · 截断的工具调用",
  "Recovery · latency · throughput": "修复率 · 延迟 · 吞吐量",
  "Baseline on the same input": "使用同一输入的基线",
  "Run 10,000 attempts": "运行 10,000 次",
  "Benchmark progress": "跑分进度",
  "Measured on this device": "在当前设备测量",
  "MoonBit JS and Wasm GC available": "MoonBit JS 与 Wasm GC 均可用",
  "Wasm GC unavailable in this browser. Using MoonBit JS.": "当前浏览器不支持 Wasm GC，已使用 MoonBit JS。",
  "Unavailable in this browser": "当前浏览器不可用",
  "{0} KiB · {1} KiB gzip": "{0} KiB · gzip 后 {1} KiB",
  "{0} raw bytes · {1} gzip -9 bytes": "原始 {0} 字节 · gzip -9 后 {1} 字节",
  "{0} µs median · {1}": "中位数 {0} µs · {1}",
  "MB/s pending": "吞吐量待计算",
  "Running on this device…": "正在当前设备运行…",
  "{0}× Wasm GC / JS speed": "Wasm GC 速度为 JS 的 {0} 倍",
  "{0}× JS / Wasm GC speed": "JS 速度为 Wasm GC 的 {0} 倍",
  "10,000 attempts per engine": "每种引擎完成 10,000 次",
  "Benchmark failed: {0}": "跑分失败：{0}",
  "50 KB stream latency": "50 KB 流式延迟",
  "UTF-16 units per chunk": "每片 UTF-16 单元数",
  "{0} units": "{0} 个单元",
  "Compare preview + Patch": "对照预览与 Patch",
  "Streams a truncated": "逐片处理截断的",
  "call on the selected engine and checks each snapshot against the whole-prefix reference.": "调用，并在当前引擎中将每份快照与全前缀重扫结果核对。",
  "Incremental": "增量处理",
  "Whole-prefix reference": "全前缀重扫",
  "Shared scale: µs per chunk": "共用纵轴 · 每片耗时（µs）",
  "Shared scale 0–{0} µs": "共用纵轴 0–{0} µs",
  "Stream benchmark progress": "流式压测进度",
  "Ready to measure": "等待测量",
  "{0} · Measuring…": "{0} · 正在测量…",
  "{0} · {1} snapshots matched · {2} ms incremental · {3} ms reference": "{0} · {1} 份快照一致 · 增量 {2} ms · 重扫 {3} ms",
  " · {0}× reference/incremental": " · 重扫耗时为增量的 {0} 倍",
  "Benchmark stopped. {0}": "压测已停止。{0}",
  "The benchmark could not append a chunk.": "压测无法追加分片。",
  "Snapshot mismatch at chunk {0}.": "第 {0} 个分片的快照不一致。",
  "The final documents did not match.": "两份最终文档不一致。",
  "Run this configuration locally": "在本地运行当前配置",
  "Copy MoonBit": "复制 MoonBit 代码",
  "Native CLI · PowerShell": "原生命令行 · PowerShell",
  "Copy PowerShell": "复制 PowerShell 命令",
  "Enable JavaScript to use the local MoonBit engine.": "启用 JavaScript 后可使用本地 MoonBit 引擎。",
  "Built with MoonBit": "使用 MoonBit 构建",
  "Budget protection": "预算保护",
  "Input exceeds the browser budget of {0} UTF-16 units.": "输入超过浏览器的 {0} 个 UTF-16 单元上限。",
  "Schema exceeds the browser budget of {0} UTF-16 units.": "Schema 超过浏览器的 {0} 个 UTF-16 单元上限。",
  "Input exceeds the browser budget of {0} lines.": "输入超过浏览器的 {0} 行上限。",
  "Nesting exceeds the browser budget of {0} levels.": "嵌套超过浏览器的 {0} 层上限。",
  "Quoted text exceeds the browser budget of {0} escape sequences.": "引号内文本超过浏览器的 {0} 个转义序列上限。",
  "Shorten the input or select a preset to continue.": "缩短输入或选择预设后可继续。",
  "The engine was not called for this input.": "此输入未交给修复引擎。",
  "No repair report is available for this input.": "此输入暂时没有修复报告。",
  "Input held by browser limits": "浏览器已拦截超预算输入",
  "The engine could not display this input. Select a preset or edit the input.": "引擎无法显示此输入。请编辑输入或选择预设。",
  '// moon.pkg imports "ZSY2221/json_repair" @repair and "moonbitlang/core/json".': '// 在 moon.pkg 中导入 "ZSY2221/json_repair" @repair 和 "moonbitlang/core/json"。',
  "# Run from the project root in PowerShell.": "# 在项目根目录打开 PowerShell 并运行。",
  "# The input file holds one JSON-RPC frame per line.": "# 输入文件按行保存，每行一个 JSON-RPC 帧。",
  "Return corrected tool arguments as JSON only. Treat actual values as data.": "只以 JSON 返回修正后的工具参数。将实际值视为数据。",
  "Fix the tool schema before retrying.": "先修正工具 Schema，再重试。",
  "Repair adjustment": "修复调整",
  "Constraint was not met.": "未满足当前约束。",
  "Semantic coercion": "语义自愈",
  "Source diagnostics": "源码诊断",
  "Open source diagnostics": "查看源码诊断",
  "Live UI Duel": "实时渲染对决",
  "Duel scenario": "对决场景",
  "Travel booking": "旅行预订",
  "E-commerce checkout": "电商结算",
  "Write file": "写入文件",
  "Start duel": "开始对决",
  "Ready to play": "准备播放",
  "Waiting to start": "等待开始",
  "The replay starts with a reasoning draft. JSON.parse receives the following JSON chunks. Wasm GC isolates the draft from the full stream and renders each patch.": "回放从推理草稿开始。JSON.parse 接收草稿之后的 JSON 分片，Wasm GC 在完整流中隔离草稿并逐次渲染补丁。",
  "No fields available yet": "暂未收到可用字段",
  "Inspect the raw model stream": "查看模型原始输出流",
  "Complete JSON": "JSON 已完整",
  "Waiting for complete JSON": "等待完整 JSON",
  "Waiting for the JSON payload": "等待 JSON 负载",
  "Isolating the reasoning draft": "正在隔离推理草稿",
  "Applying live patches": "正在应用补丁",
  "{0} Patch ops": "{0} 次补丁操作",
  "First field · Wasm {0} · strict {1}": "首字段耗时 · Wasm {0} · 严格解析 {1}",
  "Engine time · Wasm {0} · strict {1}": "引擎耗时 · Wasm {0} · 严格解析 {1}",
  "{0}/{1} chunks": "{0}/{1} 个分片",
  "Preparing Wasm GC…": "正在准备 Wasm GC…",
  "Wasm GC is unavailable in this browser.": "当前浏览器不支持 Wasm GC。",
  "Duel stream stopped": "对决流已中止",
  "Trip title": "行程标题",
  "Destination": "目的地",
  "Budget": "预算",
  "Risk": "风险",
  "Progress": "进度",
  "Order title": "订单标题",
  "Amount": "金额",
  "Currency": "币种",
  "Order ID": "订单编号",
  "File path": "文件路径",
  "Code preview": "代码预览",
  "Estimated size": "预计大小",
  "Low risk": "低风险",
  "Needs review": "需要复核",
  "Travel booking duel": "旅行预订渲染对决",
  "Watch fields appear from Wasm GC patches while JSON.parse waits for the last chunk.": "观察 Wasm GC 如何通过补丁提前渲染字段，以及 JSON.parse 何时收到完整文档。",
  "Semantic normalization": "语义规范化",
  "Normalize a field name and enum spelling while preserving the exact amount.": "规范字段名和枚举拼写，同时无损保留金额。",
  "Chaos Arena": "异常输入竞技场",
  "Run 1,152 cases": "运行 1,152 个样本",
  "Wasm GC processes seeded truncations, Unicode boundaries, reasoning blocks, quotes, and deep nesting in small batches.": "Wasm GC 分批处理固定种子生成的截断、Unicode 边界、推理块、引号及深层嵌套样本。",
  "Cases": "已处理样本",
  "Valid repairs": "有效修复",
  "Safe refusals": "安全拒绝",
  "Bridge failures": "引擎或桥接异常",
  "Engine throughput": "引擎吞吐",
  "Chaos Arena progress": "异常输入测试进度",
  "Ready to run": "准备运行",
  "Inspect a refusal": "查看拒绝诊断",
  "{0}/{1} cases checked": "已检查 {0}/{1} 个样本",
  "Chaos Arena could not finish": "异常输入测试未能完成",
  "# Use the MoonBit example for semantic coercion.": "# 如需语义自愈，请运行 MoonBit 示例。",
});

const engineChinese = Object.freeze({
  "remove line comment": "删除行注释",
  "remove block comment": "删除块注释",
  "unescape apostrophe inside converted string": "还原已转换字符串中的单引号",
  "preserve incomplete, unpaired, or unknown escape as text": "按普通文本保留不完整、未配对或未知转义",
  "replace opening apostrophe": "替换起始单引号",
  "replace closing apostrophe": "替换结束单引号",
  "escape double quote inside converted string": "转义已转换字符串中的双引号",
  "escape raw control character": "转义原始控制字符",
  "close truncated string": "补全截断的字符串",
  "quote bare object key": "为裸键名补上引号",
  "convert hexadecimal integer to decimal": "将十六进制整数无损转换为十进制",
  "normalize JSON5 decimal number": "规范化 JSON5 十进制数字",
  "complete a truncated JSON literal": "补全截断的 JSON 字面量",
  "convert non-JSON literal": "转换非 JSON 字面量",
  "remove trailing comma": "删除尾逗号",
  "close truncated array": "闭合截断数组",
  "close truncated object": "闭合截断对象",
  "insert missing comma": "插入遗漏的逗号",
  "drop final object member without a value": "删除缺少值的末尾对象成员",
  "remove text after JSON": "删除 JSON 之后的文本",
  "remove leading Unicode BOM": "删除开头的 Unicode BOM",
  "remove text before JSON": "删除 JSON 之前的文本",
  "remove opening Markdown fence": "删除 Markdown 起始围栏",
  "remove closing Markdown fence": "删除 Markdown 结束围栏",
  "ignore think block": "隔离推理块",
  "ignore unterminated think block": "隔离未闭合的推理块",
  "repair edit limit exceeded": "修复次数超过上限",
  "expected an object key": "此处应为对象键",
  "hexadecimal integer exceeds 1024 digits": "十六进制整数超过 1024 位",
  "invalid hexadecimal integer": "十六进制整数无效",
  "leading zero in number": "数字不能带前导零",
  "expected a digit": "此处应为数字",
  "expected a fractional digit": "小数点后应有数字",
  "expected an exponent digit": "指数应含数字",
  "invalid character following number": "数字后出现无效字符",
  "unrecognized JSON literal": "无法识别 JSON 字面量",
  "maximum JSON nesting depth exceeded": "超出 JSON 嵌套深度上限",
  "expected a JSON value": "此处应为 JSON 值",
  "expected a comma or matching closing delimiter": "应有逗号或配对的闭合符",
  "expected a colon after the object key": "对象键名后应有冒号",
  "object key cannot be decoded as JSON": "对象键名无法按 JSON 解码",
  "duplicate object key": "对象键名重复",
  "ambiguous or unexpected content after the JSON value": "JSON 值之后有无法判定或无效的内容",
  "expected a JSON value after removing the wrapper": "移除外层包装后，输入应包含 JSON 值",
  "maximum JSON input size exceeded": "超出 JSON 输入长度上限",
  "expected well-formed UTF-16 input": "输入需要是有效的 UTF-16 序列",
  "repaired document cannot be decoded as JSON": "修复后的文档无法按 JSON 解码",
  "maximum extracted block count exceeded": "超出可提取区块数量上限",
  "expected at least one type name": "至少应指定一种类型",
  "duplicate entry": "存在重复项",
  "expected string": "应为字符串",
  "expected array of strings": "应为字符串数组",
  "schema nesting limit exceeded": "超出 Schema 嵌套上限",
  "expected object of property schemas": "应为包含字段 Schema 的对象",
  "expected nonempty array": "应为非空数组",
  "expected number": "应为数字",
  "expected nonnegative integer": "应为非负整数",
  "unsupported keyword": "不支持的关键字",
  "expected object or boolean schema": "Schema 应为对象或布尔值",
  "expected a value from enum": "值应来自枚举",
  "required property is missing": "缺少必填属性",
  "rejected by false schema": "被 false Schema 拒绝",
  "expected a nonempty tool name": "应提供非空的工具名称",
  "tool already registered": "工具已注册",
  "expected an object mapping tool names to input schemas": "应为将工具名称映射到输入 Schema 的对象",
  "expected an encoded JSON object": "应为编码后的 JSON 对象",
  "expected an arguments object": "参数应为对象",
  "expected a params object": "params 应为对象",
  "expected a registered tool name": "应提供已注册的工具名称",
  "expected one repairable JSON-RPC object": "应提供一个可修复的 JSON-RPC 对象",
  "expected one JSON-RPC object": "应提供一个 JSON-RPC 对象",
  "expected JSON-RPC 2.0": "应使用 JSON-RPC 2.0",
  "expected a JSON-RPC method": "应提供 JSON-RPC 方法",
  "expected a string or integer id": "id 应为字符串或整数",
  "tools/call requires an id": "tools/call 需要请求 ID",
  "Parse error": "解析错误",
  "Invalid Request": "请求无效",
  "Invalid params": "参数无效",
  "strip_prose": "去除说明文本",
  "strip_fence": "去除代码围栏",
  "strip_bom": "去除 BOM",
  "remove_comment": "删除注释",
  "remove_trailing_comma": "删除尾逗号",
  "insert_comma": "插入逗号",
  "quote_key": "补全键名引号",
  "normalize_quote": "规范引号",
  "close_string": "闭合字符串",
  "escape_character": "转义字符",
  "normalize_literal": "规范字面量",
  "complete_literal": "补全字面量",
  "drop_incomplete_member": "删除不完整成员",
  "close_array": "闭合数组",
  "close_object": "闭合对象",
  "hex_int_to_decimal": "十六进制转十进制",
  "normalize_decimal": "规范十进制数字",
  "ignore_think_block": "隔离推理",
  "empty_input": "空输入",
  "unexpected_token": "意外的词元",
  "trailing_content": "多余的末尾内容",
  "invalid_number": "无效数字",
  "duplicate_key": "重复键",
  "invalid_unicode": "无效 Unicode",
  "invalid_repaired_json": "修复结果无效",
  "input_limit": "输入达到上限",
  "depth_limit": "嵌套达到上限",
  "edit_limit": "修复达到上限",
  "block_limit": "提取数量达到上限",
  "string_to_number": "字符串转数字",
  "string_to_boolean": "字符串转布尔值",
  "wrap_scalar_array": "将标量包装为数组",
  "rename_key": "规范字段名",
  "normalize_enum": "规范枚举值",
});

let labLanguage = "en";
const labLanguageKey = "moon-json-repair-lang";
const labBindings = new WeakMap();

function resolveLabLanguage(search, saved, locale) {
  const explicit = new URLSearchParams(search).get("lang");
  const supported = value => value === "zh" || value === "en";
  if (supported(explicit)) return explicit;
  if (supported(saved)) return saved;
  return /^zh/i.test(locale ?? "") ? "zh" : "en";
}

function labText(key, ...args) {
  const format = labLanguage === "zh" && Object.hasOwn(labChinese, key) ? labChinese[key] : key;
  return format.replace(/\{(\d+)\}/g, (match, index) => String(args[index] ?? match));
}

function labEngineMessage(message, fallback) {
  message = String(message ?? "");
  if (labLanguage === "en") return message || fallback;
  if (Object.hasOwn(engineChinese, message)) return engineChinese[message];
  if (message.startsWith("schema_coerce · ")) {
    return "按 Schema 修正 · " + labEngineMessage(message.slice("schema_coerce · ".length), "Repair adjustment");
  }
  for (const [pattern, replace] of [
    [/^expected number (>=|<=) (.+)$/, "应为满足 $1 $2 的数字"],
    [/^expected (at least|at most) (.+) Unicode code points$/, (_, range, count) => "应包含" + (range === "at least" ? "至少" : "至多") + count + " 个 Unicode 码点"],
    [/^unknown type (.+)$/, "未知类型 $1"],
    [/^expected one of (.+)$/, "应为下列类型之一：$1"],
    [/^expected (array|boolean|integer|null|number|object|string)$/, (_, type) => "应为" + ({
      array: "数组", boolean: "布尔值", integer: "整数", null: "空值", number: "数字", object: "对象", string: "字符串",
    })[type]],
    [/^one of (.+)$/, "应为下列值之一：$1"],
    [/^key matches multiple properties equally, including (.+) and (.+)$/, "键名与多个属性同样匹配，包括 $1 和 $2"],
    [/^key would overwrite or compete for (.+)$/, "键名可能覆盖或争用属性 $1"],
  ]) {
    if (pattern.test(message)) return message.replace(pattern, replace);
  }
  return labText(fallback);
}

// Only generated message strings change in the localized preview. Keep the
// original wire text and every untouched value, including numeric lexemes.
function localizeWireMessages(wire, translate) {
  const { pointers } = jsonView(wire);
  let localized = "";
  let offset = 0;
  for (const [pointer, { start, end }] of pointers) {
    if (wire[start] !== '"') continue;
    const original = JSON.parse(wire.slice(start, end));
    const message = translate(pointer, original);
    if (message === original) continue;
    localized += wire.slice(offset, start) + JSON.stringify(message);
    offset = end;
  }
  return localized + wire.slice(offset);
}

function labRetryPrompt(prompt) {
  if (!prompt || labLanguage === "en") return prompt;
  const line = prompt.indexOf("\n");
  if (line >= 0) {
    return labText(prompt.slice(0, line)) + "\n" + localizeWireMessages(prompt.slice(line + 1), (pointer, message) =>
      /^\/fix\/\d+\/expected$/u.test(pointer) ? labEngineMessage(message, "Constraint was not met.") : message);
  }
  const hint = /^Fix (.+?): (.+)$/s.exec(prompt);
  return hint ? "修正 " + hint[1] + "：" + labEngineMessage(hint[2], "Constraint was not met.") : prompt;
}

function labMcpFrame(frame) {
  if (labLanguage === "en") return frame;
  return localizeWireMessages(frame, (pointer, message) => {
    if (pointer === "/error/data/retry_prompt") return labRetryPrompt(message);
    if (pointer === "/error/message" || /^\/error\/data\/issues\/\d+\/message$/u.test(pointer)) {
      return labEngineMessage(message, "Constraint was not met.");
    }
    return message;
  });
}

function labBind(element, render, attribute = "textContent") {
  let specs = labBindings.get(element);
  if (!specs) {
    specs = new Map();
    labBindings.set(element, specs);
    element.setAttribute("data-lab-message", "");
  }
  specs.set(attribute, render);
  if (attribute === "textContent") element.textContent = render();
  else element.setAttribute(attribute, render());
}

function labSet(element, key, ...args) {
  labBind(element, () => labText(key, ...args));
}

function labClear(element, attribute = "textContent") {
  labBindings.get(element)?.delete(attribute);
}

function labValue(message) {
  return typeof message === "function" ? message() : labText(message);
}

function applyLabLanguage(language) {
  labLanguage = language;
  document.documentElement.lang = language === "zh" ? "zh-CN" : "en";
  for (const element of document.querySelectorAll("[data-lab-message]")) {
    for (const [attribute, render] of labBindings.get(element)) {
      if (attribute === "textContent") element.textContent = render();
      else element.setAttribute(attribute, render());
    }
  }
  for (const code of ["zh", "en"]) {
    document.getElementById("lang-" + code).setAttribute("aria-pressed", String(code === language));
  }
}

function initializeLabLanguage(onSwitch) {
  for (const element of document.querySelectorAll("[data-i18n],[data-i18n-aria],[data-i18n-placeholder],[data-i18n-description]")) {
    if (element.hasAttribute("data-i18n")) labSet(element, element.textContent.trim());
    for (const [key, attribute] of [["i18nAria", "aria-label"], ["i18nPlaceholder", "placeholder"], ["i18nDescription", "content"]]) {
      if (key in element.dataset) {
        const english = element.getAttribute(attribute);
        labBind(element, () => labText(english), attribute);
      }
    }
  }
  let saved;
  try { saved = localStorage.getItem(labLanguageKey); } catch { /* file/private mode */ }
  applyLabLanguage(resolveLabLanguage(location.search, saved, navigator.language));
  for (const language of ["zh", "en"]) {
    document.getElementById("lang-" + language).addEventListener("click", () => {
      applyLabLanguage(language);
      try { localStorage.setItem(labLanguageKey, language); } catch { /* file/private mode */ }
      const url = new URL(location.href);
      url.searchParams.set("lang", language);
      try { history.replaceState(null, "", url); } catch { /* unsupported file origin */ }
      onSwitch();
    });
  }
}

const browserLimits = Object.freeze({ source: 128_000, schema: 32_000, lines: 8_000, depth: 256, escapes: 16_000 });
const browserLimitMessages = Object.freeze({
  input_limit: "Input exceeds the browser budget of {0} UTF-16 units.",
  schema_limit: "Schema exceeds the browser budget of {0} UTF-16 units.",
  line_limit: "Input exceeds the browser budget of {0} lines.",
  depth_limit: "Nesting exceeds the browser budget of {0} levels.",
  escape_limit: "Quoted text exceeds the browser budget of {0} escape sequences.",
});

function inspectLabInput(source, schema) {
  if (source.length > browserLimits.source) return { kind: "input_limit", limit: browserLimits.source, input: "source" };
  if (schema.length > browserLimits.schema) return { kind: "schema_limit", limit: browserLimits.schema, input: "schema" };
  return inspectLabText(source, "source") ?? inspectLabText(schema, "schema");
}

function inspectLabText(text, input) {
  const stack = [];
  let quote = "";
  let escaped = false;
  let comment = "";
  let lines = 1;
  let escapes = 0;
  for (let index = 0; index < text.length; index++) {
    const unit = text[index];
    if (unit === "\n" || (unit === "\r" && text[index + 1] !== "\n")) {
      if (++lines > browserLimits.lines) return { kind: "line_limit", limit: browserLimits.lines, input, position: index };
      if (comment === "//") comment = "";
    }
    if (comment) {
      if (comment === "/*" && unit === "*" && text[index + 1] === "/") {
        comment = "";
        index++;
      }
    } else if (quote) {
      if (escaped) escaped = false;
      else if (unit === "\\") {
        escaped = true;
        if (++escapes > browserLimits.escapes) return { kind: "escape_limit", limit: browserLimits.escapes, input, position: index };
      } else if (unit === quote) quote = "";
    } else if (unit === "/" && (text[index + 1] === "/" || text[index + 1] === "*")) {
      comment = unit + text[++index];
    } else if (unit === '"' || (unit === "'" && stack.length)) {
      quote = unit;
    } else if (unit === "{" || unit === "[") {
      stack.push(unit === "{" ? "}" : "]");
      if (stack.length > browserLimits.depth) return { kind: "depth_limit", limit: browserLimits.depth, input, position: index };
    } else if (unit === stack.at(-1)) {
      stack.pop();
    }
  }
  return null;
}
