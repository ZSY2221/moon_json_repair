///|
fn thought_policy() -> @json_repair.RepairPolicy {
  @json_repair.RepairOptions::default().with_ignore_think_blocks(true)
}

///|
fn thought_edits(
  report : @json_repair.RepairReport,
) -> Array[@json_repair.RepairEdit] {
  report.edits.filter(edit => edit.code() == "ignore_think_block")
}

///|
test "think policy is opt-in and leaves legacy option literals and function types valid" {
  let options : @json_repair.RepairOptions = {
    limits: @json_repair.RepairLimits::default(),
    json5: false,
    max_blocks: 128,
  }
  let legacy : (String, @json_repair.RepairOptions) -> Result[
    @json_repair.RepairReport,
    @json_repair.RepairError,
  ] = @json_repair.repair_with_options
  let raw = "<think>{\"draft\":1}</think>{\"body\":2}"
  assert_eq(
    @json_repair.repair_with_policy(raw, @json_repair.RepairPolicy::default()),
    legacy(raw, options),
  )
  assert_eq(@json_repair.extract_all(raw, options).unwrap().length(), 2)
  assert_eq(
    @json_repair.extract_all_with_policy(raw, thought_policy())
    .unwrap()
    .length(),
    1,
  )
}

///|
test "think audit is case-insensitive and uses original UTF-16 and CRLF coordinates" {
  let prefix = "I’m preparing 🌙.\r\n"
  let draft = "<ThInK>\r\n{\"draft\":\"😀\"}\r\n</tHiNk>"
  let raw = prefix + draft + "\r\n{\"tool\":\"answer\"}"
  let report = @json_repair.repair_with_policy(raw, thought_policy()).unwrap()
  assert_eq(report.json, "{\"tool\":\"answer\"}")
  let edits = thought_edits(report)
  assert_eq(edits.length(), 1)
  let edit = edits[0]
  assert_eq(edit.position, { offset: prefix.length(), line: 2, column: 1, })
  assert_eq(edit.end_offset, prefix.length() + draft.length())
  assert_eq(edit.action, "ignore think block")
  assert_eq(edit.replacement, "")
  for other in report.edits {
    if other.code() != "ignore_think_block" {
      assert_true(
        other.end_offset <= edit.position.offset ||
        other.position.offset >= edit.end_offset,
      )
    }
  }
}

///|
test "think markup inside JSON strings and comments is literal" {
  let raw = "{\"name\":\"quoted \\\"<think>draft</think>\", 'arg':'<THINK>literal</THINK>', /* <think> ] */ \"x\":1}"
  let report = @json_repair.repair_with_policy(raw, thought_policy()).unwrap()
  assert_eq(
    report.json,
    "{\"name\":\"quoted \\\"<think>draft</think>\",\"arg\":\"<THINK>literal</THINK>\",\"x\":1}",
  )
  assert_true(thought_edits(report).is_empty())
  let raw = "\uFEFF  \"<think>literal</think>\""
  let scalar = @json_repair.repair_with_policy(raw, thought_policy()).unwrap()
  assert_eq(scalar.json, "\"<think>literal</think>\"")
  assert_true(thought_edits(scalar).is_empty())
}

///|
test "prose and Markdown do not make tags inside the selected JSON literal controls" {
  let raw = "I am ready.\n\n```json\n\"<think>literal</think>\"\n```"
  let report = @json_repair.repair_with_policy(raw, thought_policy()).unwrap()
  assert_eq(report.json, "\"<think>literal</think>\"")
  assert_true(thought_edits(report).is_empty())
  let raw = "Here is the payload: {\"arg\":\"<think>literal</think>\"}"
  let report = @json_repair.repair_with_policy(raw, thought_policy()).unwrap()
  assert_eq(report.json, "{\"arg\":\"<think>literal</think>\"}")
  assert_true(thought_edits(report).is_empty())
}

///|
test "prose brackets do not hide a real thought boundary after an apostrophe" {
  let raw = "A note [this isn't JSON\n<think>{\"draft\":1}</think>{\"body\":2}"
  let blocks = @json_repair.extract_all_with_policy(raw, thought_policy()).unwrap()
  assert_eq(blocks.map(block => block.report.json), ["{\"body\":2}"])
  assert_eq(thought_edits(blocks[0].report).length(), 1)
}

///|
test "closing markup inside reasoning JSON cannot reveal later draft candidates" {
  let raw = "<think>{\"literal\":\"escaped \\\"</think>\"}{\"draft\":2}</think>{\"answer\":3}"
  let reports = @json_repair.extract_all_with_policy(raw, thought_policy()).unwrap()
  assert_eq(reports.map(block => block.report.json), ["{\"answer\":3}"])
  let edit = thought_edits(reports[0].report)[0]
  assert_eq(edit.end_offset, reports[0].start.offset)
}

///|
test "line-aligned closing markup fences a malformed draft string" {
  let raw = "<think>\n{\"draft\":\"unfinished\n  </think>\n{\"body\":1}"
  let result = @json_repair.repair_with_policy(raw, thought_policy()).unwrap()
  assert_eq(result.json, "{\"body\":1}")
  assert_eq(thought_edits(result)[0].action, "ignore think block")
}

///|
test "multiline reasoning strings protect a closing marker on a line of its own" {
  let raw = "<think>{\"draft\":\"\n</think>\ntext\"}\n{\"also_draft\":1}\n</think>\n{\"body\":2}"
  let blocks = @json_repair.extract_all_with_policy(raw, thought_policy()).unwrap()
  assert_eq(blocks.map(block => block.report.json), ["{\"body\":2}"])
  let edits = thought_edits(blocks[0].report)
  assert_eq(edits.length(), 1)
  assert_eq(edits[0].end_offset + 1, blocks[0].start.offset)
}

///|
test "a draft prefix with indeterminate multiline quote does not reveal a candidate" {
  let raw = "<think>{\"draft\":\"\n</think>\n{draft:1}"
  let stream = @json_repair.RepairStream::with_policy(thought_policy())
  assert_eq(stream.push(raw), Ok(()))
  assert_true(stream.preview() is Err(_))
  assert_true(
    @json_repair.extract_all_with_policy(raw, thought_policy())
    .unwrap()
    .is_empty(),
  )
}

///|
test "ambiguous inline closing markup after a broken quote stays isolated" {
  let raw = "<think>{\"draft\":\"unfinished</think>{\"body\":1}"
  let error = @json_repair.repair_with_policy(raw, thought_policy()).unwrap_err()
  assert_eq(error.kind, EmptyInput)
  assert_true(
    @json_repair.extract_all_with_policy(raw, thought_policy())
    .unwrap()
    .is_empty(),
  )
}

///|
test "nested think regions form one audit and thinking-only text gives no candidate" {
  let raw = "<think>before<THINK>{\"draft\":1}</think>after</THINK>"
  let report = @json_repair.repair_with_policy(raw + "true", thought_policy()).unwrap()
  assert_eq(report.json, "true")
  let edits = thought_edits(report)
  assert_eq(edits.length(), 1)
  assert_eq(edits[0].end_offset, raw.length())
  assert_true(
    @json_repair.extract_all_with_policy(raw, thought_policy())
    .unwrap()
    .is_empty(),
  )
}

///|
test "unterminated think markup masks to end of reply without consuming a prior tool call" {
  let body = "{\"id\":9007199254740993}"
  let raw = body + "\r\n <think>{\"draft\":1}\r\n\"😀\n"
  let report = @json_repair.repair_with_policy(raw, thought_policy()).unwrap()
  assert_eq(report.json, body)
  let edit = thought_edits(report)[0]
  assert_eq(edit.position, { offset: body.length() + 3, line: 2, column: 2, })
  assert_eq(edit.end_offset, raw.length())
  assert_eq(edit.action, "ignore unterminated think block")
}

///|
test "multi-block audits attach once to neighboring candidates with absolute offsets" {
  let ranges = ["<think>a</think>", "<THINK>中😀</THINK>", "<think>draft"]
  let first = "{\"call\":1}"
  let second = "{\"call\":9007199254740993}"
  let raw = ranges[0] + first + ranges[1] + second + ranges[2]
  let blocks = @json_repair.extract_all_with_policy(raw, thought_policy()).unwrap()
  assert_eq(blocks.map(block => block.report.json), [first, second])
  assert_eq(blocks[0].start.offset, ranges[0].length())
  assert_eq(blocks[0].end.offset, ranges[0].length() + first.length())
  assert_eq(thought_edits(blocks[0].report).map(edit => edit.position.offset), [
    0,
  ])
  assert_eq(thought_edits(blocks[1].report).map(edit => edit.position.offset), [
    blocks[0].end.offset,
    blocks[1].end.offset,
  ])
  assert_eq(thought_edits(blocks[1].report)[1].end_offset, raw.length())
}

///|
test "think isolation also works between JSON members and with JSON5 enabled" {
  let policy = thought_policy()
  let options = { ..policy.options, json5: true, }
  let raw = "{\"a\":1,<think>{\"draft\":2}</think>\"b\":0x20000000000001}"
  let report = @json_repair.repair_with_policy(raw, { ..policy, options, }).unwrap()
  assert_eq(report.json, "{\"a\":1,\"b\":9007199254740993}")
  assert_eq(report.edits.map(edit => edit.code()), [
    "ignore_think_block", "hex_int_to_decimal",
  ])
  let blocks = @json_repair.extract_all_with_policy(raw, { ..policy, options, }).unwrap()
  assert_eq(blocks[0].report, report)
}

///|
test "ignored reasoning consumes repair edit budget in every applicable API" {
  let policy = thought_policy()
  let limits = { ..policy.options.limits, max_edits: 0, }
  let options = { ..policy.options, limits, }
  let policy = { ..policy, options, }
  let raw = "<think>draft</think>{\"body\":1}"
  let expected : @json_repair.SourcePosition = {
    offset: 0,
    line: 1,
    column: 1,
  }
  let single = @json_repair.repair_with_policy(raw, policy).unwrap_err()
  let multi = @json_repair.extract_all_with_policy(raw, policy).unwrap_err()
  assert_eq(single.kind, EditLimit)
  assert_eq(single.position, expected)
  assert_eq(multi, single)
}

///|
test "stream isolates split think markup and batch preview is identical after final push" {
  let stream = @json_repair.RepairStream::with_policy(thought_policy())
  for
    part in ["<Th", "InK>\r", "\n{\"draft\":\"😀", " unfinished\r", "\n</tH"] {
    assert_eq(stream.push(part), Ok(()))
    assert_eq(stream.status().depth, 0)
    assert_true(stream.status().quote is None)
    assert_true(stream.preview() is Err(_))
  }
  assert_eq(stream.push("iNk>\r\n{\"answer\":"), Ok(()))
  assert_eq(stream.status().position.line, 4)
  assert_eq(stream.status().depth, 1)
  assert_eq(stream.status().stack, ["}"])
  assert_eq(stream.push("9007199254740993}"), Ok(()))
  let raw = "<ThInK>\r\n{\"draft\":\"😀 unfinished\r\n</tHiNk>\r\n{\"answer\":9007199254740993}"
  assert_eq(stream.status().stable_offset, raw.length())
  assert_true(stream.status().stable)
  let expected = @json_repair.repair_with_policy(raw, thought_policy())
  assert_eq(stream.preview(), expected)
  assert_eq(stream.finalize(), expected)
  assert_true(stream.status().finalized)
  stream.reset()
  assert_eq(stream.status().position, { offset: 0, line: 1, column: 1, })
  assert_false(stream.status().finalized)
}
