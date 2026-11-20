///|
fn expect_failure_wire(
  input : String,
  code : String,
  limits~ : @json_repair.RepairLimits = @json_repair.RepairLimits::default(),
) -> Unit raise {
  guard @json_repair.repair(input, limits~) is Err(error) else {
    fail("expected \{code} failure")
  }
  assert_eq(error.kind.code(), code)
  guard @json.to_json(error)
    is {
      "kind": String(kind),
      "message": String(message),
      "position": Object(_),
      ..
    } else {
    fail("missing public error fields")
  }
  assert_eq(kind, code)
  assert_true(message.length() > 0)
}

///|
test "empty input has a structured empty_input error" {
  expect_failure_wire(" \t\r\n", "empty_input")
}

///|
test "unexpected root punctuation serializes its failure kind" {
  expect_failure_wire("]", "unexpected_token")
}

///|
test "invalid decimal serializes its failure kind" {
  expect_failure_wire("[01]", "invalid_number")
}

///|
test "duplicate property serializes its failure kind" {
  expect_failure_wire("{\"x\":1,\"x\":2}", "duplicate_key")
}

///|
test "a second root serializes as trailing content" {
  expect_failure_wire("{} {\"x\":2}", "trailing_content")
}

///|
test "negative input budget treats even one byte as too many" {
  let limits : @json_repair.RepairLimits = {
    ..@json_repair.RepairLimits::default(),
    max_input: -10,
  }
  expect_failure_wire("{}", "input_limit", limits~)
}

///|
test "negative depth budget still permits a single root container" {
  let limits : @json_repair.RepairLimits = {
    ..@json_repair.RepairLimits::default(),
    max_depth: -5,
  }
  assert_eq(@json_repair.repair("{}", limits~).unwrap().json, "{}")
  expect_failure_wire("[[0]]", "depth_limit", limits~)
}

///|
test "negative edit budget still permits a fully valid document" {
  let limits : @json_repair.RepairLimits = {
    ..@json_repair.RepairLimits::default(),
    max_edits: -50,
  }
  assert_eq(@json_repair.repair("[0]", limits~).unwrap().edits.length(), 0)
  expect_failure_wire("[0,", "edit_limit", limits~)
}

///|
test "native UTF-16 high-surrogate truncation reports the raw offset" {
  let input = "[\"🌙"
  let split = input.unsafe_substring(start=0, end=3)
  expect_failure_wire(split, "invalid_unicode")
  let error = @json_repair.repair(split).unwrap_err()
  assert_eq(error.position.offset, 2)
  assert_eq(error.position.column, 3)
}

///|
test "an orphaned high surrogate cannot be joined with plain ASCII" {
  let input = "🌙"
  let split = input.unsafe_substring(start=0, end=1)
  expect_failure_wire("[\"" + split + "a\"]", "invalid_unicode")
}

///|
test "a leading low surrogate cannot enter the Markdown scanner" {
  let input = "🌙"
  let split = input.unsafe_substring(start=1, end=2)
  expect_failure_wire(split + "[1]", "invalid_unicode")
}

///|
test "array candidates in prose recognize uppercase and JavaScript literal starts" {
  for
    (raw, expected) in [
      ("intent\n[True]", "[true]"),
      ("intent\n[None]", "[null]"),
      ("intent\n[undefined]", "[null]"),
    ] {
    assert_eq(@json_repair.repair(raw).unwrap().json, expected)
  }
}

///|
test "bare object candidates in prose skip malformed placeholders" {
  let report = @json_repair.repair(
    "Result {9 parts}, then {sample    : true}。完成",
  ).unwrap()
  assert_eq(report.json, "{\"sample\":true}")
  assert_eq(report.edits.map(e => e.kind.code()), [
    "strip_prose", "quote_key", "strip_prose",
  ])
}

///|
test "unrecognized but plausible literal prefixes stop without invention" {
  expect_failure_wire("[nodes", "unexpected_token")
  expect_failure_wire("[tango", "unexpected_token")
}

///|
test "truncated Python and JSON literal initials produce audited canonical values" {
  for
    (raw, canonical) in [("[n", "[null]"), ("[T", "[true]"), ("[F", "[false]")] {
    let report = @json_repair.repair(raw).unwrap()
    assert_eq(report.json, canonical)
    assert_eq(report.edits.map(e => e.kind.code()), [
      "complete_literal", "close_array",
    ])
  }
}

///|
test "unexpected punctuation at an object key is rejected" {
  expect_failure_wire("{@:1}", "unexpected_token")
}

///|
test "bom, control and unknown escape edits retain explicit wire codes" {
  let report = @json_repair.repair("\uFEFF[\"a\r\\q\", True,").unwrap()
  guard @json.to_json(report) is { "edits": Array(edits), .. } else {
    fail("report lost edits")
  }
  let codes = edits.map(edit => {
    match edit {
      { "kind": String(code), .. } => code
      _ => ""
    }
  })
  assert_eq(codes, [
    "strip_bom", "escape_control", "escape_backslash", "normalize_literal", "remove_trailing_comma",
    "close_array",
  ])
}

///|
test "schema rejects empty type unions and malformed required lists" {
  let invalid_schema : Json = { "type": [], "required": "x" }
  let errors = @json_repair.validate(Json::null(), invalid_schema)
  assert_eq(errors.map(e => (e.path, e.keyword)), [
    ("$schema.required", "required"),
    ("$schema.type", "type"),
  ])
}

///|
test "schema refuses direct integers carrying malformed decimal representations" {
  let schema : Json = { "type": "integer" }
  for repr in ["9e", "2e+", "3e-", "1e9a", ".", "e0", "1..2"] {
    let malformed = Json::number(1.0, repr~)
    assert_eq(@json_repair.validate(malformed, schema).map(e => e.keyword), [
      "type",
    ])
  }
}

///|
test "exact enum comparison recognizes the same ratio through a zero exponent" {
  let schema : Json = { "enum": [Json::number(12.0, repr="12e+000")] }
  assert_eq(@json_repair.validate(Json::number(12.0), schema).length(), 0)
}

///|
test "number ordering distinguishes two rounded-zero values across signs" {
  let bound = Json::number(0.0, repr="1e-70000")
  let sample = Json::number(-0.0, repr="-5e-70000")
  let schema : Json = { "minimum": bound }
  assert_eq(@json_repair.validate(sample, schema).map(e => e.keyword), [
    "minimum",
  ])
}

///|
test "enum comparison distinguishes keys and recursively unequal array content" {
  let schema : Json = {
    "enum": [{ "b": [1, 2] }, { "y": [0] }, { "x": [1, 2] }],
  }
  let value : Json = { "x": [1, 3] }
  assert_eq(@json_repair.validate(value, schema).map(e => e.keyword), ["enum"])
}
