///|
fn audit_spans(
  report : @json_repair.RepairReport,
) -> Array[(String, Int32, Int32, Int32, Int32, String)] {
  report.edits.map(edit => {
    (
      edit.kind.code(),
      edit.position.offset,
      edit.position.line,
      edit.position.column,
      edit.end_offset,
      edit.replacement,
    )
  })
}

///|
test "audit records a comma inserted at the next key after a line break" {
  let report = @json_repair.repair("{\"x\":1\n \"y\":2}").unwrap()
  assert_eq(audit_spans(report), [("insert_comma", 8, 2, 2, 8, ",")])
}

///|
test "audit records exactly the trailing comma span" {
  let report = @json_repair.repair("[1, ]").unwrap()
  assert_eq(audit_spans(report), [("remove_trailing_comma", 2, 1, 3, 3, "")])
}

///|
test "audit records the full source span of a quoted bare key" {
  let report = @json_repair.repair("{run:1}").unwrap()
  assert_eq(audit_spans(report), [("quote_key", 1, 1, 2, 4, "\"run\"")])
}

///|
test "audit separates opening quote escaping and closing quote changes" {
  let report = @json_repair.repair("['a\"b']").unwrap()
  assert_eq(audit_spans(report), [
    ("normalize_quote", 1, 1, 2, 2, "\""),
    ("normalize_quote", 3, 1, 4, 4, "\\\""),
    ("normalize_quote", 5, 1, 6, 6, "\""),
  ])
}

///|
test "audit records the exact block and line comment spans" {
  let report = @json_repair.repair("/*g*/ [1, // hi\r\n2]").unwrap()
  assert_eq(audit_spans(report), [
    ("remove_comment", 0, 1, 1, 5, ""),
    ("remove_comment", 10, 1, 11, 15, ""),
  ])
}

///|
test "audit escapes CRLF characters individually and counts one line break" {
  let report = @json_repair.repair("[\"go\r\nnow\"]").unwrap()
  assert_eq(audit_spans(report), [
    ("escape_control", 4, 1, 5, 5, "\\r"),
    ("escape_control", 5, 2, 1, 6, "\\n"),
  ])
}

///|
test "audit offsets and columns measure UTF-16 after an emoji" {
  let report = @json_repair.repair("[\"😀\",None]").unwrap()
  assert_eq(audit_spans(report), [("normalize_literal", 6, 1, 7, 10, "null")])
}

///|
test "audit strips leading prose when a literal lookahead crosses an emoji" {
  let report = @json_repair.repair("tru😀\n{\"a\":1}").unwrap()
  assert_eq(audit_spans(report), [("strip_prose", 0, 1, 1, 6, "")])
}

///|
test "audit closes nested containers from inside out at the same EOF" {
  let report = @json_repair.repair("[{\"x\":[1").unwrap()
  assert_eq(audit_spans(report), [
    ("close_array", 8, 1, 9, 8, "]"),
    ("close_object", 8, 1, 9, 8, "}"),
    ("close_array", 8, 1, 9, 8, "]"),
  ])
}

///|
test "audit report has a machine-readable JSON snapshot" {
  let report = @json_repair.repair("[None]").unwrap()
  let expected : Json = {
    "json": "[null]",
    "value": [null],
    "edits": [
      {
        "kind": "normalize_literal",
        "action": "convert non-JSON literal",
        "position": { "offset": 1, "line": 1, "column": 2 },
        "end_offset": 5,
        "replacement": "null",
      },
    ],
  }
  assert_eq(@json.to_json(report), expected)
}

///|
test "stream previews a partial string and replaces its temporary closure" {
  let stream = @json_repair.RepairStream::new()
  stream.push("{\"name\":\"mo").unwrap()
  let prefix = stream.preview().unwrap()
  assert_eq(prefix.value, { "name": "mo" })
  assert_eq(prefix.edits.map(edit => edit.kind.code()), [
    "close_string", "close_object",
  ])
  stream.push("on\"}").unwrap()
  let complete = stream.preview().unwrap()
  assert_eq(complete.value, { "name": "moon" })
  assert_true(complete.edits.is_empty())
}

///|
test "stream joins chunks split inside a block comment marker" {
  let stream = @json_repair.RepairStream::new()
  stream.push("[/").unwrap()
  stream.push("*note*").unwrap()
  stream.push("/true]").unwrap()
  let report = stream.preview().unwrap()
  assert_eq(report.value, [true])
  assert_eq(audit_spans(report), [("remove_comment", 1, 1, 2, 9, "")])
}

///|
test "stream joins chunks split inside a Unicode escape" {
  let stream = @json_repair.RepairStream::new()
  stream.push("[\"\\uD8").unwrap()
  stream.push("3D\\uDE").unwrap()
  stream.push("00\"]").unwrap()
  let report = stream.preview().unwrap()
  assert_eq(report.value, ["😀"])
  assert_true(report.edits.is_empty())
}

///|
test "stream recomputes original coordinates across a CRLF chunk boundary" {
  let stream = @json_repair.RepairStream::new()
  stream.push("[\r").unwrap()
  stream.push("\n None]").unwrap()
  let report = stream.preview().unwrap()
  assert_eq(audit_spans(report), [("normalize_literal", 4, 2, 2, 8, "null")])
}

///|
test "stream rejections leave the previous prefix and its input budget usable" {
  let limits : @json_repair.RepairLimits = {
    max_input: 5,
    max_depth: 8,
    max_edits: 8,
  }
  let stream = @json_repair.RepairStream::new(limits~)
  stream.push("[1").unwrap()
  let previous = stream.preview().unwrap()
  match stream.push(",222]") {
    Err(error) => assert_eq(error.kind.code(), "input_limit")
    Ok(_) => fail("input exceeded the configured limit")
  }
  assert_eq(stream.preview().unwrap(), previous)
  stream.push(",2]").unwrap()
  assert_eq(stream.preview().unwrap().json, "[1,2]")
}

///|
test "stream preview leaves its audit and source stable across repeated calls" {
  let stream = @json_repair.RepairStream::new()
  stream.push("{name:\"moon\"").unwrap()
  let first = stream.preview().unwrap()
  let second = stream.preview().unwrap()
  assert_eq(first, second)
  assert_eq(second.edits.map(edit => edit.kind.code()), [
    "quote_key", "close_object",
  ])
}

///|
test "stream accepts empty chunks without altering its output" {
  let stream = @json_repair.RepairStream::new()
  stream.push("[]").unwrap()
  let previous = stream.preview().unwrap()
  stream.push("").unwrap()
  assert_eq(stream.preview().unwrap(), previous)
}

///|
test "stream reset clears the old source and permits independent input" {
  let stream = @json_repair.RepairStream::new()
  stream.push("[None").unwrap()
  assert_true(!stream.preview().unwrap().edits.is_empty())
  stream.reset()
  match stream.preview() {
    Err(error) => assert_eq(error.kind.code(), "empty_input")
    Ok(_) => fail("reset stream should be empty")
  }
  stream.push("[true]").unwrap()
  let report = stream.preview().unwrap()
  assert_eq(report.value, [true])
  assert_true(report.edits.is_empty())
}
