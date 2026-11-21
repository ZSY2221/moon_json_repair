///|
fn extension_json5() -> @json_repair.RepairOptions {
  let defaults = @json_repair.RepairOptions::default()
  { ..defaults, json5: true, }
}

///|
fn extension_expect_json5(input : String, expected : String) -> Unit raise {
  guard @json_repair.repair_with_options(input, extension_json5()) is Ok(report) else {
    fail("JSON5 input was rejected")
  }
  assert_eq(report.json, expected)
  guard @json_repair.repair(report.json) is Ok(repaired_again) else {
    fail("normalized output did not pass the legacy parser")
  }
  assert_eq(repaired_again.json, expected)
  assert_true(repaired_again.edits.is_empty())
}

///|
fn extension_error(
  input : String,
  options : @json_repair.RepairOptions,
) -> @json_repair.RepairError raise {
  guard @json_repair.repair_with_options(input, options) is Err(error) else {
    fail("expected a repair error")
  }
  error
}

///|
fn extension_blocks(input : String) -> Array[@json_repair.ExtractedBlock] raise {
  guard @json_repair.extract_all(input, @json_repair.RepairOptions::default())
    is Ok(blocks) else {
    fail("expected successful extraction")
  }
  blocks
}

///|
test "default options preserve the legacy hex error and location" {
  let input = "[\r\n 0x10]"
  let error = extension_error(input, @json_repair.RepairOptions::default())
  assert_eq(@json_repair.repair(input), Err(error))
  assert_eq(error.kind, InvalidNumber)
  assert_eq(error.position, { offset: 4, line: 2, column: 2, })
}

///|
test "default options reject each decimal extension at its first code unit" {
  for raw in ["+12", ".5", "5."] {
    let error = extension_error(raw, @json_repair.RepairOptions::default())
    assert_eq(@json_repair.repair(raw), Err(error))
    assert_eq(error.position.offset, 0)
    assert_eq(error.position.line, 1)
    assert_eq(error.position.column, 1)
  }
}

///|
test "JSON5 audit covers the complete numeric source span" {
  let raw = "[0x10,\r\n+.5]"
  guard @json_repair.repair_with_options(raw, extension_json5()) is Ok(report) else {
    fail("numeric repairs expected")
  }
  assert_eq(report.edits.length(), 2)
  assert_eq(report.edits[0].position, { offset: 1, line: 1, column: 2, })
  assert_eq(report.edits[0].end_offset, 5)
  assert_eq(report.edits[0].replacement, "16")
  assert_eq(report.edits[0].code(), "hex_int_to_decimal")
  assert_eq(report.edits[1].position, { offset: 8, line: 2, column: 1, })
  assert_eq(report.edits[1].end_offset, 11)
  assert_eq(report.edits[1].replacement, "0.5")
  assert_eq(report.edits[1].code(), "normalize_decimal")
}

///|
test "JSON5 hex conversion supports multiple decimal limbs" {
  extension_expect_json5(
    "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "115792089237316195423570985008687907853269984665640564039457584007913129639935",
  )
}

///|
test "JSON5 permits at most 1024 hex digits" {
  extension_expect_json5("0x" + "0".repeat(1023) + "1", "1")
  let error = extension_error("0x" + "F".repeat(1025), extension_json5())
  assert_eq(error.kind, InvalidNumber)
  assert_eq(error.position.offset, 0)
}

///|
test "JSON5 conversion consumes the same repair edit budget" {
  let options = extension_json5()
  let limits = { ..options.limits, max_edits: 1, }
  let error = extension_error("[0x10,.5]", { ..options, limits, })
  assert_eq(error.kind, EditLimit)
  assert_eq(error.position.offset, 6)
}

///|
test "opt-in single document repair recognizes JSON5 Markdown fences" {
  let raw = "```json5\n[0x10]\n```"
  extension_expect_json5(raw, "[16]")
  assert_true(@json_repair.repair(raw) is Err(_))
}

///|
test "extraction finds an array truncated inside a literal" {
  let blocks = extension_blocks("Tool returned [tru")
  assert_eq(blocks.map(block => block.report.json), ["[true]"])
  assert_eq(blocks[0].report.edits[0].kind, CompleteLiteral)
}

///|
test "extraction completes a fenced partial scalar" {
  let blocks = extension_blocks("```json\n tru\n```")
  assert_eq(blocks.map(block => block.report.json), ["true"])
  assert_eq(blocks[0].report.edits[0].kind, CompleteLiteral)
}

///|
test "extraction ignores candidate-like text in leading fenced comments" {
  let raw = "```jsonc\n// {\"fake\":1}\n/* {\"fake\":2} */{\"real\":3}\n```"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), ["{\"real\":3}"])
}

///|
test "extraction returns inline and fenced candidates in source order" {
  let raw = "🌙 tool1 {name:'a'}\r\n```json\r\n[2,3,]\r\n```\r\nthen {\"x\":4} done"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), [
    "{\"name\":\"a\"}", "[2,3]", "{\"x\":4}",
  ])
  assert_eq(blocks[0].start, { offset: 9, line: 1, column: 10, })
  assert_eq(blocks[1].start.line, 3)
  assert_eq(blocks[1].end.column, 7)
  assert_eq(blocks[2].end.offset - blocks[2].start.offset, 7)
}

///|
test "extraction keeps absolute UTF16 audit positions" {
  let raw = "🌙\r\n   [0,]"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.length(), 1)
  assert_eq(blocks[0].start, { offset: 7, line: 2, column: 4, })
  assert_eq(blocks[0].report.edits[0].position, {
    offset: 9,
    line: 2,
    column: 6,
  })
  assert_eq(blocks[0].report.edits[0].end_offset, 10)
  assert_eq(blocks[0].end, { offset: 11, line: 2, column: 8, })
}

///|
test "extraction preserves line-relative edits inside a candidate" {
  let blocks = extension_blocks("prefix {\"x\":\r\n  True} end")
  let edit = blocks[0].report.edits[0]
  assert_eq(edit.position, { offset: 16, line: 2, column: 3, })
  assert_eq(edit.end_offset, 20)
  assert_eq(edit.replacement, "true")
}

///|
test "extraction chooses the exact nested block extent" {
  let blocks = extension_blocks("{\"text\":\"{[]}\",\"args\":{\"n\":[1,2]}}[3]")
  assert_eq(blocks.length(), 2)
  assert_eq(blocks[0].report.json, "{\"text\":\"{[]}\",\"args\":{\"n\":[1,2]}}")
  assert_eq(blocks[0].end, blocks[1].start)
  assert_eq(blocks[1].report.json, "[3]")
}

///|
test "extraction recognizes titles and skips non-json code fences" {
  let raw = "```js\n{\"fake\":true}\n```\n~~~ JSONC\n{\"real\":1}\n~~~\n{}"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), ["{\"real\":1}", "{}"])
  assert_eq(blocks.map(block => block.confidence), [100, 95])
}

///|
test "extraction supports fenced scalar values and ignores naked scalars" {
  let raw = "13 considered\n```\n  7\n```\n```application/json\n\"ok\"\n```"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), ["7", "\"ok\""])
  assert_eq(blocks[0].start.column, 3)
  assert_eq(blocks[0].end.column, 4)
}

///|
test "extraction accepts longer fences and incomplete matching close" {
  let raw = "```` JSON\n[1]\n```\n[2]\n````\n[3]"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), ["[1]", "[2]", "[3]"])
  assert_eq(blocks.map(block => block.confidence), [100, 100, 95])
}

///|
test "extraction ends truncated strings at a Markdown boundary" {
  let raw = "```json\n{\"a\":\"cut\n```\n{\"b\":7}"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.length(), 2)
  assert_eq(blocks[0].report.json, "{\"a\":\"cut\\n\"}")
  assert_eq(blocks[0].end.line, 3)
  assert_eq(blocks[0].end.column, 1)
  assert_true(blocks[0].confidence < blocks[1].confidence)
}

///|
test "extraction infers a boundary at a new unindented bare object" {
  let raw = "{\"a\":1\n{\"b\":2}"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), ["{\"a\":1}", "{\"b\":2}"])
  assert_eq(blocks[0].end, blocks[1].start)
  assert_eq(blocks[0].report.edits[0].position, blocks[0].end)
}

///|
test "extraction recovers adjacent equally indented bare objects" {
  let raw = "  {tool:'first'\n  {tool:'second'}"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), [
    "{\"tool\":\"first\"}", "{\"tool\":\"second\"}",
  ])
  assert_eq(blocks[1].start.column, 3)
}

///|
test "extraction recovers a completed member before trailing prose" {
  let raw = "{tool:'first'\nSummary with words.\n{tool:'second'}"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), [
    "{\"tool\":\"first\"}", "{\"tool\":\"second\"}",
  ])
}

///|
test "extraction keeps an unindented nested object after a colon" {
  let raw = "{\"nested\":\n{\"inside\":2}}"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), [
    "{\"nested\":{\"inside\":2}}",
  ])
}

///|
test "extraction leaves missing-comma repair inside an open array" {
  let raw = "[{\"a\":1}\n{\"b\":2}]"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), ["[{\"a\":1},{\"b\":2}]"])
  assert_eq(blocks[0].report.edits[0].kind, InsertComma)
}

///|
test "extraction ignores delimiter-looking content in comments" {
  let raw = "{a:1,/* } ] */ b:[2// ] } ignored\n]} {}"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), [
    "{\"a\":1,\"b\":[2]}", "{}",
  ])
}

///|
test "extraction skips mismatched and unrepairable candidates" {
  let raw = "A {var} B [word] {\"b\":bad} [}] C {\"ok\":true}"
  let blocks = extension_blocks(raw)
  assert_eq(blocks.map(block => block.report.json), ["{\"ok\":true}"])
}

///|
test "extraction ignores JSON5 unless configured" {
  let raw = "A {\"x\":0x20000000000001} B [2] C [.5]"
  let default_blocks = extension_blocks(raw)
  assert_eq(default_blocks.map(block => block.report.json), ["[2]"])
  guard @json_repair.extract_all(raw, extension_json5()) is Ok(blocks) else {
    fail("expected three repaired blocks")
  }
  assert_eq(blocks.map(block => block.report.json), [
    "{\"x\":9007199254740993}", "[2]", "[0.5]",
  ])
}

///|
test "extraction limits successful blocks and reports the next location" {
  let options = { ..@json_repair.RepairOptions::default(), max_blocks: 1, }
  guard @json_repair.extract_all("{} then []", options) is Err(error) else {
    fail("second successful candidate must exceed the limit")
  }
  assert_eq(error.kind, InputLimit)
  assert_eq(error.position.offset, 8)
}

///|
test "extraction distinguishes zero block budget from no blocks" {
  let options = { ..@json_repair.RepairOptions::default(), max_blocks: -1, }
  assert_eq(@json_repair.extract_all("no tools", options), Ok([]))
  assert_true(@json_repair.extract_all("{}", options) is Err(_))
}

///|
test "extraction caps requested block counts at 4096" {
  let options = { ..@json_repair.RepairOptions::default(), max_blocks: 5000, }
  guard @json_repair.extract_all("{}".repeat(4097), options) is Err(error) else {
    fail("maximum block budget was not clamped")
  }
  assert_eq(error.position.offset, 8192)
}

///|
test "extraction enforces the input cap over prose and candidates" {
  let options = @json_repair.RepairOptions::default()
  let limits = { ..options.limits, max_input: 4, }
  guard @json_repair.extract_all("abcd {}", { ..options, limits, })
    is Err(error) else {
    fail("full input should exceed max_input")
  }
  assert_eq(error.kind, InputLimit)
  assert_eq(error.position.offset, 0)
}

///|
test "extraction returns absolute positions for exhausted edit budgets" {
  let options = @json_repair.RepairOptions::default()
  let limits = { ..options.limits, max_edits: 0, }
  guard @json_repair.extract_all("prefix {a:1}", { ..options, limits, })
    is Err(error) else {
    fail("an exhausted edit budget should be visible")
  }
  assert_eq(error.kind, EditLimit)
  assert_eq(error.position, { offset: 8, line: 1, column: 9, })
}

///|
test "extraction does not silently skip depth limit failures" {
  let options = @json_repair.RepairOptions::default()
  let limits = { ..options.limits, max_depth: 1, }
  guard @json_repair.extract_all("lead\n[[1]]", { ..options, limits, })
    is Err(error) else {
    fail("an exhausted nesting budget should be visible")
  }
  assert_eq(error.kind, DepthLimit)
  assert_eq(error.position, { offset: 6, line: 2, column: 2, })
}

///|
test "extraction repairs a final truncated container" {
  let blocks = extension_blocks("tool [1,2")
  assert_eq(blocks[0].report.json, "[1,2]")
  assert_eq(blocks[0].report.edits[0].kind, CloseArray)
  assert_eq(blocks[0].report.edits[0].position, blocks[0].end)
}

///|
test "extraction returns no candidates for prose" {
  assert_eq(
    extension_blocks("Punctuation like [word], {placeholder}. Consider 0.5."),
    [],
  )
}

///|
test "stream status increments UTF16 positions and exposes full stack" {
  let stream = @json_repair.RepairStream::new()
  assert_eq(stream.push("{\"a\":[\"🌙"), Ok(()))
  let status = stream.status()
  assert_eq(status.position, { offset: 9, line: 1, column: 10, })
  assert_eq(status.depth, 2)
  assert_eq(status.stack, ["}", "]"])
  assert_eq(status.quote, Some("\""))
  assert_false(status.stable)
  assert_eq(status.stable_offset, 0)
}

///|
test "stream double-quote escape carries across chunks" {
  let stream = @json_repair.RepairStream::new()
  assert_eq(stream.push("{\"a\":\"x\\"), Ok(()))
  assert_eq(stream.push("\"{\""), Ok(()))
  assert_eq(stream.status().quote, None)
  assert_eq(stream.status().stack, ["}"])
  assert_eq(stream.push("}"), Ok(()))
  assert_true(stream.status().stable)
}

///|
test "stream single-quoted strings ignore delimiters" {
  let stream = @json_repair.RepairStream::new()
  assert_eq(stream.push("{a:'["), Ok(()))
  assert_eq(stream.status().quote, Some("'"))
  assert_eq(stream.status().stack, ["}"])
  assert_eq(stream.push("]'}"), Ok(()))
  assert_true(stream.status().stable)
}

///|
test "stream comment delimiters work when split at slash and star" {
  let stream = @json_repair.RepairStream::new()
  for chunk in ["[1/", "*} *", "/", ",2]"] {
    assert_eq(stream.push(chunk), Ok(()))
  }
  assert_false(stream.status().in_comment)
  assert_true(stream.status().stable)
  assert_eq(stream.finalize(), @json_repair.repair("[1/*} */,2]"))
}

///|
test "stream tracks line comments and split carriage-return line feeds" {
  let stream = @json_repair.RepairStream::new()
  assert_eq(stream.push("[1//"), Ok(()))
  assert_true(stream.status().in_comment)
  assert_eq(stream.push(" } \r"), Ok(()))
  assert_false(stream.status().in_comment)
  assert_eq(stream.push("\n,2]"), Ok(()))
  assert_eq(stream.status().position, { offset: 12, line: 2, column: 4, })
  assert_true(stream.status().stable)
}

///|
test "stream counts separate line breaks around an ordinary UTF-16 text run" {
  let stream = @json_repair.RepairStream::new()
  for chunk in ["[\"\r", "🌙 text", "\n\"]"] {
    assert_eq(stream.push(chunk), Ok(()))
  }
  let status = stream.status()
  assert_eq(status.position, { offset: 13, line: 3, column: 3, })
  assert_eq(status.stable_offset, 13)
  assert_true(status.stable)
  assert_eq(stream.finalize(), @json_repair.repair("[\"\r🌙 text\n\"]"))
}

///|
test "stream position remains unchanged after an oversized chunk" {
  let defaults = @json_repair.RepairLimits::default()
  let stream = @json_repair.RepairStream::new(limits={
    ..defaults,
    max_input: 5,
  })
  assert_eq(stream.push("["), Ok(()))
  assert_eq(stream.push("\r\n1"), Ok(()))
  let before = stream.status()
  guard stream.push("]]") is Err(error) else {
    fail("overflow should reject the whole chunk")
  }
  assert_eq(error.kind, InputLimit)
  assert_eq(error.position, before.position)
  assert_eq(stream.status(), before)
  assert_eq(stream.push("]"), Ok(()))
  assert_eq(stream.finalize(), @json_repair.repair("[\r\n1]"))
}

///|
test "stream stable offset survives additional whitespace" {
  let stream = @json_repair.RepairStream::new()
  assert_eq(stream.push("{}"), Ok(()))
  assert_true(stream.status().stable)
  assert_eq(stream.push("\n \t"), Ok(()))
  assert_true(stream.status().stable)
  assert_eq(stream.status().stable_offset, 2)
  assert_eq(stream.status().position.offset, 5)
}

///|
test "stream status detects nontrivia after a stable root" {
  let stream = @json_repair.RepairStream::new()
  assert_eq(stream.push("{}"), Ok(()))
  assert_eq(stream.push("[]"), Ok(()))
  assert_false(stream.status().stable)
  assert_eq(stream.status().stable_offset, 2)
  guard stream.finalize() is Err(error) else {
    fail("batch repair must reject competing roots")
  }
  assert_eq(error.kind, TrailingContent)
}

///|
test "stream finalize preserves the true incomplete source state" {
  let stream = @json_repair.RepairStream::new()
  let input = "{\"a\":\"preview"
  assert_eq(stream.push(input), Ok(()))
  assert_false(stream.status().finalized)
  assert_eq(stream.preview(), stream.finalize())
  assert_eq(stream.finalize(), @json_repair.repair(input))
  assert_true(stream.status().finalized)
  assert_false(stream.status().stable)
  assert_eq(stream.status().quote, Some("\""))
}

///|
test "stream reset clears finalized state and checkpoints" {
  let stream = @json_repair.RepairStream::new()
  assert_eq(stream.push("{}"), Ok(()))
  assert_eq(stream.finalize(), @json_repair.repair("{}"))
  assert_true(stream.push("[]") is Err(_))
  stream.reset()
  assert_eq(stream.status(), @json_repair.RepairStream::new().status())
  assert_eq(stream.push("[]"), Ok(()))
  assert_eq(stream.finalize(), @json_repair.repair("[]"))
}

///|
test "stream incrementally checkpoints top-level strings" {
  let stream = @json_repair.RepairStream::new()
  assert_eq(stream.push("\"ok"), Ok(()))
  assert_false(stream.status().stable)
  assert_eq(stream.push("\""), Ok(()))
  assert_true(stream.status().stable)
  assert_eq(stream.status().stable_offset, 4)
}

///|
test "stream status caps displayed stack while tracking true depth" {
  let defaults = @json_repair.RepairLimits::default()
  let stream = @json_repair.RepairStream::new(limits={
    ..defaults,
    max_depth: 2,
  })
  assert_eq(stream.push("[[[1"), Ok(()))
  assert_eq(stream.status().depth, 3)
  assert_eq(stream.status().stack, ["]", "]"])
  assert_eq(stream.push("]]]"), Ok(()))
  assert_eq(stream.status().depth, 0)
  assert_false(stream.status().stable)
  guard stream.finalize() is Err(error) else {
    fail("depth limit must still apply")
  }
  assert_eq(error.kind, DepthLimit)
}

///|
test "stream still reports batch errors on mismatched closers" {
  let stream = @json_repair.RepairStream::new()
  assert_eq(stream.push("[}"), Ok(()))
  assert_false(stream.status().stable)
  assert_eq(stream.status().stack, ["]"])
  assert_eq(stream.finalize(), @json_repair.repair("[}"))
}

///|
test "stream opt-in numbers converge with identical audit" {
  let opts = extension_json5()
  let stream = @json_repair.RepairStream::with_options(opts)
  for chunk in ["[0", "x20000000", "000001,+", ".5]"] {
    assert_eq(stream.push(chunk), Ok(()))
  }
  let raw = "[0x20000000000001,+.5]"
  assert_eq(stream.finalize(), @json_repair.repair_with_options(raw, opts))
  assert_true(stream.status().stable)
}

///|
test "stream finalization seals even a failed empty snapshot" {
  let stream = @json_repair.RepairStream::new()
  assert_eq(stream.finalize(), @json_repair.repair(""))
  assert_true(stream.status().finalized)
  assert_true(stream.push("{}") is Err(_))
}

///|
test "JSON5 converts positive and negative hex signs" {
  extension_expect_json5("[0x10,-0xF,0X2A,+0xa,-0x0]", "[16,-15,42,10,-0]")
}

///|
test "JSON5 preserves large exact integers" {
  extension_expect_json5(
    "[0x20000000000001,-0x20000000000001,9007199254740993]", "[9007199254740993,-9007199254740993,9007199254740993]",
  )
}

///|
test "JSON5 inserts leading fractional zeros" {
  extension_expect_json5("[.5,-.5,+.5]", "[0.5,-0.5,0.5]")
}

///|
test "JSON5 inserts trailing fractional zeros" {
  extension_expect_json5("[5.,-5.,+5.]", "[5.0,-5.0,5.0]")
}

///|
test "JSON5 keeps original exponent spellings" {
  extension_expect_json5(
    "[+.5E-09,5.E+01,-.7e2,+12e3]", "[0.5E-09,5.0E+01,-0.7e2,12e3]",
  )
}

///|
test "JSON5 handles permissive array separators" {
  extension_expect_json5("[1 +2 .5]", "[1,2,0.5]")
}

///|
test "JSON5 preserves strict literals and quoted text" {
  extension_expect_json5(
    "[0,1.5,-2e+01,\".5\",\"0x10\",\"+3\"]", "[0,1.5,-2e+01,\".5\",\"0x10\",\"+3\"]",
  )
}

///|
test "JSON5 handles scalar decimals without wrappers" {
  extension_expect_json5("+.5", "0.5")
}

///|
test "JSON5 recognizes numeric array after leading text" {
  extension_expect_json5("Tool result: [+.5,5.,0x10] done", "[0.5,5.0,16]")
}

///|
test "JSON5 tolerates comments after hex" {
  extension_expect_json5("[0x10/* test */]", "[16]")
}

///|
test "JSON5 rejects a hex prefix without digits" {
  let error = extension_error("[0x]", extension_json5())
  assert_eq(error.kind, InvalidNumber)
}

///|
test "JSON5 rejects a trailing identifier on hex" {
  let error = extension_error("[-0x12z]", extension_json5())
  assert_eq(error.kind, InvalidNumber)
}

///|
test "JSON5 rejects hexadecimal fractional notation" {
  let error = extension_error("[0x1.2]", extension_json5())
  assert_eq(error.kind, InvalidNumber)
}

///|
test "JSON5 rejects multiple signs" {
  let error = extension_error("+--1", extension_json5())
  assert_eq(error.kind, InvalidNumber)
}

///|
test "JSON5 still rejects decimal leading zeros" {
  let error = extension_error("[+012]", extension_json5())
  assert_eq(error.kind, InvalidNumber)
}

///|
test "JSON5 rejects a bare decimal point" {
  let error = extension_error("[.]", extension_json5())
  assert_eq(error.kind, InvalidNumber)
}

///|
test "JSON5 requires exponent digits" {
  let error = extension_error("[.5e+]", extension_json5())
  assert_eq(error.kind, InvalidNumber)
}

///|
test "JSON5 rejects a second decimal point" {
  let error = extension_error("[1..]", extension_json5())
  assert_eq(error.kind, InvalidNumber)
}
