///|
fn render_test_error(
  source : String,
  offset : Int32,
  kind~ : RepairFailureKind = UnexpectedToken,
  ansi~ : Bool = false,
  chinese~ : Bool = false,
) -> String {
  render_diagnostic(
    source,
    Repair({
      kind,
      message: "test error",
      position: { offset, line: 1, column: offset + 1, },
    }),
    ansi~,
    chinese~,
  )
}

///|
fn render_test_edit(
  source : String,
  kind : RepairKind,
  start : Int32,
  finish : Int32,
  replacement : String,
  chinese~ : Bool = false,
) -> String {
  render_diagnostic(
    source,
    Edit({
      kind,
      action: "test edit",
      position: { offset: start, line: 1, column: start + 1, },
      end_offset: finish,
      replacement,
    }),
    chinese~,
  )
}

///|
fn render_test_schema(
  source : String,
  path : String,
  keyword : String,
  chinese~ : Bool = false,
) -> String {
  render_diagnostic(
    source,
    Schema({ path, keyword, message: "test constraint", }),
    chinese~,
  )
}

///|
test "pretty repair failure preserves original CRLF and UTF-16 coordinates" {
  let source = "{\r\n  \"城市😀\": @\r\n}"
  guard repair_with_options(source, RepairOptions::default()) is Err(error) else {
    fail("expected repair failure")
  }
  assert_eq(error.position.line, 2)
  assert_eq(error.position.column, 11)
  let output = render_diagnostic(source, Repair(error))
  assert_true(output.contains(" --> 2:11 (UTF-16)"))
  assert_true(
    output.contains("1 | {\n2 |   \"城市😀\": @\n  |             ^\n3 | }"),
  )
  assert_false(output.contains("\r"))
  assert_true(output.contains("= help:"))
}

///|
test "pretty diagnostic expands tab stops after wide characters" {
  let output = render_test_error("中😀\tx", 4)
  assert_true(output.contains(" --> 1:5 (UTF-16)"))
  assert_true(output.contains("1 | 中😀    x\n  |         ^"))
}

///|
test "pretty terminal output escapes control and bidi characters" {
  let output = render_test_error("a\u001b[0m\u0085\u202eZ", 8)
  assert_false(output.contains("\u001b"))
  assert_true(output.contains("a\\u001b[0m\\u0085\\u202eZ"))
  assert_true(output.contains(" --> 1:9 (UTF-16)"))
}

///|
test "pretty terminal output clamps a negative external diagnostic offset" {
  assert_true(render_test_error("{}", -10).contains(" --> 1:1 (UTF-16)"))
}

///|
test "pretty terminal output clamps a paste past the end" {
  assert_true(render_test_error("{}", 999).contains(" --> 1:3 (UTF-16)"))
}

///|
test "pretty insertion at end after lone carriage return anchors to blank line" {
  let output = render_test_error("abc\r", 4)
  assert_true(output.contains(" --> 2:1 (UTF-16)"))
  assert_true(output.contains("1 | abc\n2 | \n  | ^"))
}

///|
test "pretty insertion points between CR and LF follow repair line accounting" {
  let output = render_test_error("a\r\nb", 2)
  assert_true(output.contains(" --> 2:1 (UTF-16)"))
  assert_true(output.contains("2 | b\n  | ^"))
}

///|
test "pretty empty input renders the first line" {
  let output = render_test_error("", 0, kind=EmptyInput)
  assert_true(output.contains("error[empty_input]"))
  assert_true(output.contains("1 | \n  | ^"))
  assert_true(output.contains("Provide one JSON value."))
}

///|
test "pretty audit marks display cells for an exact wide-character removal" {
  let output = render_test_edit("a中😀z", StripProse, 1, 4, "")
  assert_true(output.contains("edit[strip_prose]"))
  assert_true(output.contains("1 | a中😀z\n  |  ^^^^"))
  assert_true(output.contains("An empty replacement removes the marked span."))
}

///|
test "pretty audit caret bounds a multiline edit to its first line" {
  let output = render_test_edit("abc\ndef", StripProse, 1, 6, "")
  assert_true(output.contains("1 | abc\n  |  ^^\n2 | def"))
}

///|
test "pretty replacement and custom error messages are safe terminal text" {
  let replacement = render_test_edit("abc", QuoteKey, 0, 1, "\\n\u001b\n")
  assert_true(replacement.contains("Replace with \\n\\u001b\\u000a"))
  let error : RepairError = {
    kind: UnexpectedToken,
    message: "\u001b\u200e" + "m".repeat(340),
    position: { offset: 0, line: 1, column: 1, },
  }
  let output = render_diagnostic("a", Repair(error))
  assert_true(output.contains("\\u001b\\u200e"))
  assert_true(output.contains("mmm…\n"))
}

///|
test "pretty language selection does not alter the raw source or machine code" {
  let output = render_test_error(
    "{\"x\":1,\"x\":2}",
    7,
    kind=DuplicateKey,
    chinese=true,
  )
  assert_true(output.contains("错误[duplicate_key]：对象键重复"))
  assert_true(output.contains("建议：删除重复键"))
  assert_true(output.contains("{\"x\":1,\"x\":2}"))
  let audit = render_test_edit("x", QuoteKey, 0, 1, "\"x\"", chinese=true)
  assert_true(audit.contains("编辑[quote_key]：为对象键加引号"))
  assert_true(audit.contains("建议：替换为 \"x\""))
}

///|
test "pretty ANSI colors error and edit categories separately" {
  let error = render_test_error("@", 0, ansi=true)
  assert_true(error.contains("\u001b[1;31merror[unexpected_token]\u001b[0m"))
  assert_true(error.contains("\u001b[1;31m^\u001b[0m"))
  let report = repair_with_options("{a:1,}", RepairOptions::default()).unwrap()
  let audit = render_repair_audit("{a:1,}", report.edits, ansi=true)
  assert_true(audit.contains("\u001b[1;36medit[quote_key]\u001b[0m"))
}

///|
test "pretty clips a long active row around its caret" {
  let source = "a".repeat(200) + "X" + "b".repeat(200)
  let output = render_test_error(source, 200)
  assert_true(output.contains(" --> 1:201 (UTF-16)"))
  assert_true(
    output.contains("1 | …" + "a".repeat(36) + "X" + "b".repeat(59) + "…"),
  )
  assert_true(output.length() < 300)
}

///|
test "pretty clipping does not split a surrogate pair at either boundary" {
  let source = "a".repeat(63) +
    "😀" +
    "b".repeat(94) +
    "😀" +
    "c".repeat(100)
  let output = render_test_error(source, 100)
  assert_true(output.contains("1 | …😀"))
  assert_true(output.contains("😀…\n"))
  assert_false(output.contains("\\ud83d"))
  assert_false(output.contains("\\ude00"))
}

///|
test "pretty caret lines align when the source reaches double-digit line numbers" {
  let source = "\n".repeat(8) + "a\nb\nc"
  let output = render_test_error(source, 10)
  assert_true(output.contains(" 9 | a\n10 | b\n   | ^\n11 | c"))
}

///|
test "pretty schema locates a nested array value and quoted Unicode key" {
  let source = "{\r\n  \"城市😀\": [1,\r\n    \"wrong\"]\r\n}"
  let schema = @json.parse(
    "{\"properties\":{\"城市😀\":{\"items\":{\"type\":\"integer\"}}}}",
  )
  let issues = validate(@json.parse(source[:]), schema)
  assert_eq(issues.length(), 1)
  let output = render_diagnostic(source, Schema(issues[0]))
  assert_true(output.contains("error[type]: expected integer"))
  assert_true(output.contains(" --> 3:5 (UTF-16) $[\"城市😀\"][1]"))
  assert_true(output.contains("3 |     \"wrong\"]\n  |     ^^^^^^^"))
}

///|
test "pretty schema tracks an escaped key containing delimiters" {
  let source = "{\"a.\\u005b\\\"\\\\\": 17}"
  let output = render_test_schema(source, "$[\"a.[\\\"\\\\\"]", "maximum")
  assert_true(output.contains(" --> 1:18 (UTF-16)"))
  assert_true(output.contains("^^\n"))
}

///|
test "pretty schema walks normal dot paths through multiple objects" {
  let source = "{\"outer\":{\"inner\":{\"n\":9007199254740993}}}"
  let output = render_test_schema(source, "$.outer.inner.n", "maximum")
  assert_true(output.contains("9007199254740993"))
  assert_true(output.contains("^^^^^^^^^^^^^^^^\n"))
  assert_true(output.contains("$.outer.inner.n"))
}

///|
test "pretty schema keeps a definition namespace and highlights its rule" {
  let source = "{\n \"type\": \"oops\"\n}"
  let schema = @json.parse(source[:])
  let issues = validate(Json::boolean(true), schema)
  assert_eq(issues.length(), 1)
  let output = render_diagnostic(source, Schema(issues[0]))
  assert_true(output.contains(" --> 2:10 (UTF-16) $schema.type"))
  assert_true(output.contains("^^^^^^\n"))
  assert_true(output.contains("Correct this rule in the schema definition."))
  let zh = render_diagnostic(source, Schema(issues[0]), chinese=true)
  assert_true(zh.contains("错误[type]：约束定义无效"))
}

///|
test "pretty missing schema field anchors to nearest containing object" {
  let source = "{\n  \"parent\": {}\n}"
  let schema = @json.parse(
    "{\"properties\":{\"parent\":{\"required\":[\"child\"]}}}",
  )
  let issues = validate(@json.parse(source[:]), schema)
  let output = render_diagnostic(source, Schema(issues[0]), chinese=true)
  assert_true(output.contains("错误[required]：缺少必填字段"))
  assert_true(output.contains(" --> 2:13 (UTF-16) $.parent.child"))
  assert_true(output.contains("^^\n"))
}

///|
test "pretty missing array index anchors to its containing empty array" {
  let output = render_test_schema("{\"items\":[]}", "$.items[0]", "type")
  assert_true(output.contains(" --> 1:10 (UTF-16)"))
  assert_true(output.contains("^^\n"))
}

///|
test "pretty schema root scalar anchors after leading whitespace" {
  let output = render_test_schema("\r\n  false  \n", "$", "enum")
  assert_true(output.contains(" --> 2:3 (UTF-16) $"))
  assert_true(output.contains("  |   ^^^^^"))
}

///|
test "pretty schema rejects unavailable lexical text instead of blaming a partial child" {
  let absent = render_test_schema("{\"x\":\"unterminated", "$.x", "type")
  let trailing = render_test_schema("{\"x\":1} {}", "$.x", "type")
  assert_true(absent.contains(" --> 1:1 (UTF-16)"))
  assert_true(trailing.contains(" --> 1:1 (UTF-16)"))
}

///|
test "pretty diagnostics can summarize multiple distinct source positions" {
  let source = "{\n  \"x\": 12,\n  \"y\": 34\n}"
  let output = render_diagnostics(source, [
    Schema({ path: "$.x", keyword: "maximum", message: "too high", }),
    Schema({ path: "$.y", keyword: "minimum", message: "too low", }),
  ])
  assert_true(output.contains(" --> 2:8 (UTF-16) $.x"))
  assert_true(output.contains(" --> 3:8 (UTF-16) $.y"))
  assert_true(output.contains("retry.\n\nerror[minimum]"))
  assert_eq(render_diagnostics(source, []), "")
}

///|
test "pretty audit bounds individual entries and retains the true total" {
  let source = "{a:1,b:2,c:3,d:4,e:5,f:6,g:7,h:8,i:9,j:10}"
  let report = repair_with_options(source, RepairOptions::default()).unwrap()
  assert_eq(report.edits.length(), 10)
  let output = render_repair_audit(source, report.edits)
  assert_true(output.has_prefix("Repair audit: 10 edits"))
  assert_true(output.contains("2 more in the structured audit."))
  let zh = render_repair_audit(source, report.edits, chinese=true)
  assert_true(zh.has_prefix("修复审计：10 项编辑"))
  assert_true(zh.contains("另有 2 项，详见结构化审计。"))
}

///|
test "pretty clean audit and invalid Unicode preserve clear output" {
  assert_eq(render_repair_audit("42", []), "Repair audit: 0 edits\n")
  let source = "\u202ex"
  let trace = render_test_error(source, 1, kind=InvalidUnicode, chinese=true)
  assert_true(trace.contains("Unicode 字符或转义无效"))
  assert_true(trace.contains("\\u202ex"))
}

///|
test "pretty bilingual suggestions cover every structural failure category" {
  let rows = [
    (EmptyInput, "输入为空", "Provide one JSON value"),
    (UnexpectedToken, "无法识别的 JSON 标记", "Check the marked value"),
    (InvalidUnicode, "字符或转义无效", "Use a Unicode scalar"),
    (InvalidNumber, "数字格式无效", "Use valid JSON decimal syntax"),
    (DuplicateKey, "对象键重复", "Remove the duplicate key"),
    (TrailingContent, "还有其他内容", "extract the blocks separately"),
    (DepthLimit, "最大嵌套深度", "Reduce the number of nested containers"),
    (InputLimit, "输入长度预算", "split it into independent documents"),
    (EditLimit, "修复编辑预算", "Correct recurring formatting problems"),
  ]
  for row in rows {
    let (kind, zh, en) = row
    assert_true(render_test_error("", 0, kind~, chinese=true).contains(zh))
    assert_true(render_test_error("", 0, kind~).contains(en))
  }
}

///|
test "pretty Chinese audits give an action for every repair edit category" {
  let rows = [
    (StripProse, "移除 JSON 外的说明文字"),
    (StripFence, "移除代码围栏"),
    (StripBom, "移除字节顺序标记"),
    (RemoveComment, "移除注释"),
    (RemoveTrailingComma, "移除尾随逗号"),
    (InsertComma, "补上分隔逗号"),
    (QuoteKey, "为对象键加引号"),
    (NormalizeQuote, "规范字符串引号"),
    (EscapeControl, "转义控制字符"),
    (EscapeBackslash, "转义反斜杠"),
    (NormalizeLiteral, "规范字面量"),
    (CompleteLiteral, "补全字面量"),
    (CloseString, "闭合字符串"),
    (CloseArray, "闭合数组"),
    (CloseObject, "闭合对象"),
    (DropIncompleteMember, "去掉未完成的对象成员"),
  ]
  for row in rows {
    let (kind, zh) = row
    let output = render_test_edit("a", kind, 0, 1, "", chinese=true)
    assert_true(output.contains("编辑[\{kind.code()}]：\{zh}"))
    assert_true(output.contains("空替换表示移除原片段。"))
  }
  let source = "<think>draft</think>{\"ok\":true}"
  let report = repair_with_policy(source, {
    options: RepairOptions::default(),
    ignore_think_blocks: true,
  }).unwrap()
  assert_true(
    render_repair_audit(source, report.edits, chinese=true).contains(
      "编辑[ignore_think_block]：隔离推理草稿",
    ),
  )
}

///|
test "pretty Chinese schema messages retain their machine keyword" {
  let rows = [
    ("type", "类型与定义不符"),
    ("required", "缺少必填字段"),
    ("enum", "允许的枚举列表"),
    ("minimum", "低于最小值"),
    ("maximum", "超过最大值"),
    ("minLength", "短于最小长度"),
    ("maxLength", "超过最大长度"),
    ("additionalProperties", "对象包含未定义的键"),
    ("depth", "校验嵌套深度"),
    ("ambiguous_key", "键名可匹配多个属性"),
    ("key_collision", "迁移键名会与现有属性冲突"),
    ("semantic_key", "未满足约束条件"),
  ]
  for row in rows {
    let (keyword, zh) = row
    let output = render_test_schema("{}", "$", keyword, chinese=true)
    assert_true(output.contains("错误[\{keyword}]："))
    assert_true(output.contains(zh))
  }
}

///|
test "pretty source ranges ignore invalid partial object and array navigation" {
  for
    source in [
      "{unquoted:1}",
      "{\"bad\\q\":1}",
      "{\"x\":1",
      "[1",
      "[1,]",
      "[".repeat(259) + "0" + "]".repeat(259),
    ] {
    let output = render_test_schema(source, "$.x", "type")
    assert_true(output.contains(" --> 1:1 (UTF-16) $.x"))
  }
}

///|
test "pretty path locator skips irrelevant child paths and preserves combining mark alignment" {
  let source = "{\"skipped\":{\"many\":[\"e\u0301\",0]},\"x\":2}"
  let output = render_test_schema(source, "$.x", "type")
  assert_true(output.contains(" --> 1:34 (UTF-16) $.x"))
  let combining = render_test_error("e\u0301x", 2)
  assert_true(combining.contains("1 | e\u0301x\n  |  ^"))
}

///|
test "pretty caret aligns after regional flags, emoji joins, variation selectors and keycaps" {
  for
    prefix in ["🇨🇳", "👩🏽‍💻", "✈️", "1️⃣", "😀\u200d"] {
    let output = render_test_error(prefix + "x", prefix.length())
    assert_true(output.contains(" --> 1:\{prefix.length() + 1} (UTF-16)"))
    assert_true(output.contains("1 | \{prefix}x\n  |   ^"))
  }
  let dangling_join = render_test_error("✈️\u200d", 0)
  assert_true(dangling_join.contains("1 | ✈️\u200d\n  | ^"))
}

///|
test "pretty terminal text replaces isolated UTF-16 units with readable escapes" {
  let high = String::from_array([(0xD83D).unsafe_to_char()])
  let low = String::from_array([(0xDE00).unsafe_to_char()])
  assert_true(
    render_test_error(high + "x", 1).contains("1 | \\ud83dx\n  |       ^"),
  )
  assert_true(
    render_test_error(low + "y", 1).contains("1 | \\ude00y\n  |       ^"),
  )
  assert_true(
    render_test_error("a" + low + "y", 2).contains(
      "1 | a\\ude00y\n  |        ^",
    ),
  )
}
