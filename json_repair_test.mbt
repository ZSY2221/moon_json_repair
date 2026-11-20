///|
fn expect_repaired(input : String, expected : String) -> Unit raise {
  guard @json_repair.repair(input) is Ok(report) else {
    fail("expected repair success for \{input}")
  }
  assert_eq(report.json, expected)
  ignore(
    @json.parse(
      report.json[:],
      preserve_number_repr=true,
      reject_duplicate_keys=true,
    ),
  )
  guard @json_repair.repair(report.json) is Ok(again) else {
    fail("repair produced an unusable result")
  }
  assert_eq(again.json, report.json)
  assert_true(again.edits.is_empty())
}

///|
fn expect_repair_error(
  input : String,
  kind : @json_repair.RepairFailureKind,
) -> Unit raise {
  guard @json_repair.repair(input) is Err(error) else {
    fail("expected a repair error for \{input}")
  }
  assert_eq(error.kind, kind)
}

///|
test "strict object and stable field order" {
  expect_repaired(
    " { \"long\": 1, \"b\": true, \"a\": null } ", "{\"long\":1,\"b\":true,\"a\":null}",
  )
}

///|
test "strict mixed nested arrays" {
  expect_repaired("[{},[1, null],[],false]", "[{},[1,null],[],false]")
}

///|
test "empty object" {
  expect_repaired("{}", "{}")
}

///|
test "empty array" {
  expect_repaired("[]", "[]")
}

///|
test "strict root string" {
  expect_repaired("\"MoonBit\"", "\"MoonBit\"")
}

///|
test "strict root number" {
  expect_repaired("-1.2E+04 ", "-1.2E+04")
}

///|
test "strict root true" {
  expect_repaired(" true ", "true")
}

///|
test "strict root false" {
  expect_repaired("\tfalse", "false")
}

///|
test "strict root null" {
  expect_repaired("null\n", "null")
}

///|
test "precise large integers and exponent spelling" {
  expect_repaired(
    "[9007199254740993,1e+500,1e-9999,-0,1.00]", "[9007199254740993,1e+500,1e-9999,-0,1.00]",
  )
}

///|
test "actual non Latin and astral characters" {
  expect_repaired("{\"乐观\":\"你好🚀\"}", "{\"乐观\":\"你好🚀\"}")
}

///|
test "strict escaped surrogate pair spelling" {
  expect_repaired("\"\\uD83D\\uDE04\"", "\"\\uD83D\\uDE04\"")
}

///|
test "legal slash and control escapes are preserved" {
  expect_repaired(
    "\"a\\/b\\t\\n\\f\\r\\u0000\"", "\"a\\/b\\t\\n\\f\\r\\u0000\"",
  )
}

///|
test "strips a Unicode BOM" {
  expect_repaired("﻿{\"k\":1}", "{\"k\":1}")
}

///|
test "truncated empty object" {
  expect_repaired("{", "{}")
}

///|
test "truncated empty array" {
  expect_repaired("[", "[]")
}

///|
test "truncated root string" {
  expect_repaired("\"half 🐇", "\"half 🐇\"")
}

///|
test "truncated nested tool output" {
  expect_repaired(
    "{\"tool\":\"travel\",\"args\":{\"stops\":[\"SIN\",\"NRT", "{\"tool\":\"travel\",\"args\":{\"stops\":[\"SIN\",\"NRT\"]}}",
  )
}

///|
test "truncated value absent after colon" {
  expect_repaired("{\"a\":1,\"incomplete\":", "{\"a\":1}")
}

///|
test "truncated bare key is dropped" {
  expect_repaired("{partial_key", "{}")
}

///|
test "truncated quoted key is dropped" {
  expect_repaired("{\"a\":1,\"bc", "{\"a\":1}")
}

///|
test "truncated known JSON boolean literal" {
  expect_repaired("{\"ready\":tru", "{\"ready\":true}")
}

///|
test "truncated Python None literal" {
  expect_repaired("[Non", "[null]")
}

///|
test "truncated JS undefined literal" {
  expect_repaired("[undef", "[null]")
}

///|
test "truncated array with trailing comma" {
  expect_repaired("[1,", "[1]")
}

///|
test "truncated object with trailing comma" {
  expect_repaired("{\"a\":1, ", "{\"a\":1}")
}

///|
test "array trailing comma with whitespace" {
  expect_repaired("[1, 2, \n ]", "[1,2]")
}

///|
test "object trailing comma after a comment" {
  expect_repaired("{\"a\":1,/* dangling */}", "{\"a\":1}")
}

///|
test "missing commas between scalars" {
  expect_repaired("[1 2 true null \"y\"]", "[1,2,true,null,\"y\"]")
}

///|
test "missing commas between containers" {
  expect_repaired("[{}{}[3][4]]", "[{},{},[3],[4]]")
}

///|
test "missing commas between properties" {
  expect_repaired(
    "{\"a\":1\"b\":2 bare:false}", "{\"a\":1,\"b\":2,\"bare\":false}",
  )
}

///|
test "quote ASCII bare keys" {
  expect_repaired(
    "{foo_bar:1, $env:2, kebab-case:3}", "{\"foo_bar\":1,\"$env\":2,\"kebab-case\":3}",
  )
}

///|
test "convert single quoted keys and nested values" {
  expect_repaired(
    "{'user': ['Alice', 'Bob']}", "{\"user\":[\"Alice\",\"Bob\"]}",
  )
}

///|
test "convert escaped apostrophe and raw double quote" {
  expect_repaired("'O\\'Brien said \"yes\"'", "\"O'Brien said \\\"yes\\\"\"")
}

///|
test "normalize Python and JavaScript literal spellings" {
  expect_repaired("[True, False, None, undefined]", "[true,false,null,null]")
}

///|
test "line comments outside strings" {
  expect_repaired("[1 // first\r\n 2 // second\n]", "[1,2]")
}

///|
test "block comments outside strings" {
  expect_repaired(
    "/* head */ {\"a\"/* key */:/* value */ 1} /* tail */", "{\"a\":1}",
  )
}

///|
test "truncated block comment after value" {
  expect_repaired("[1 /* unfinished", "[1]")
}

///|
test "comment markers inside string stay literal" {
  expect_repaired(
    "[\"https://moonbitlang.com\",\"/* plain */\",\"//\"]", "[\"https://moonbitlang.com\",\"/* plain */\",\"//\"]",
  )
}

///|
test "escape raw newlines and tabs" {
  expect_repaired(
    "{\"k\":\"line 1\nline 2\r\n\tindent\"}", "{\"k\":\"line 1\\nline 2\\r\\n\\tindent\"}",
  )
}

///|
test "escape all raw C0 forms in strings" {
  expect_repaired("\"\u0000\u001b\b\f\"", "\"\\u0000\\u001b\\b\\f\"")
}

///|
test "preserve unknown string escape as literal text" {
  expect_repaired("\"C:\\queen\"", "\"C:\\\\queen\"")
}

///|
test "preserve incomplete Unicode escape as text" {
  expect_repaired("[\"\\u1F", "[\"\\\\u1F\"]")
}

///|
test "preserve dangling backslash as literal text" {
  expect_repaired("\"folder\\", "\"folder\\\\\"")
}

///|
test "prose before and after object" {
  expect_repaired(
    "Here are the tool arguments.\n{task:\"find\"}\nDone!", "{\"task\":\"find\"}",
  )
}

///|
test "ignores bracketed prose before an actual list" {
  expect_repaired("Output follows [notes]\n[1 2]\nAll done.", "[1,2]")
}

///|
test "Unicode after near-keyword prefix is safe" {
  expect_repaired("tru😀\n{\"tool\":\"run\"}", "{\"tool\":\"run\"}")
}

///|
test "Markdown json fence and transport prose" {
  expect_repaired(
    "Generated response\r\n  ```JSON\r\n{tool:\"search\"}\r\n```\r\nHope this helps.",
    "{\"tool\":\"search\"}",
  )
}

///|
test "Markdown unlabeled fence on scalar" {
  expect_repaired("```\nTrue\n```", "true")
}

///|
test "Markdown unclosed fence and JSON container" {
  expect_repaired("```json\n{\"args\":[1,2", "{\"args\":[1,2]}")
}

///|
test "Markdown closing fence bounds truncated multiline string" {
  expect_repaired(
    "```json\n{\"value\":\"first line\n```\nDone.", "{\"value\":\"first line\\n\"}",
  )
}

///|
test "nested comment and single quote" {
  expect_repaired(
    "{/* root */ item: {'x': '\\u4F60'}, enabled:True}", "{\"item\":{\"x\":\"\\u4F60\"},\"enabled\":true}",
  )
}

///|
test "reject blank input" {
  expect_repair_error("  \r\n\t", EmptyInput)
}

///|
test "reject comments only" {
  expect_repair_error("// no output", EmptyInput)
}

///|
test "reject fences only" {
  expect_repair_error("```json\n```", EmptyInput)
}

///|
test "reject curly mismatch inside array" {
  expect_repair_error("[1}", UnexpectedToken)
}

///|
test "reject square mismatch inside object" {
  expect_repair_error("{\"a\":1]", UnexpectedToken)
}

///|
test "reject missing interior value" {
  expect_repair_error("{\"a\":}", UnexpectedToken)
}

///|
test "reject missing colon" {
  expect_repair_error("{\"a\" 1}", UnexpectedToken)
}

///|
test "reject elision inside array" {
  expect_repair_error("[1,,3]", UnexpectedToken)
}

///|
test "reject bare text as a value" {
  expect_repair_error("{\"a\":yes}", UnexpectedToken)
}

///|
test "reject arbitrary text without JSON" {
  expect_repair_error("I could not process the request.", UnexpectedToken)
}

///|
test "reject partial literal with a delimiter" {
  expect_repair_error("[tru]", UnexpectedToken)
}

///|
test "reject merged keyword spellings" {
  expect_repair_error("[truefalse]", UnexpectedToken)
}

///|
test "reject leading-zero numeric token" {
  expect_repair_error("[01]", InvalidNumber)
}

///|
test "reject incomplete decimal token" {
  expect_repair_error("{\"a\":1.", InvalidNumber)
}

///|
test "reject incomplete exponent token" {
  expect_repair_error("[1e+", InvalidNumber)
}

///|
test "reject glued numeric tokens" {
  expect_repair_error("[1-2]", InvalidNumber)
}

///|
test "reject second object root" {
  expect_repair_error("{} {}", TrailingContent)
}

///|
test "reject second array after suffix prose" {
  expect_repair_error("{} and also [1]", TrailingContent)
}

///|
test "reject a scalar suffix without an envelope" {
  expect_repair_error("true then explanation", TrailingContent)
}

///|
test "reject second nonstructured JSON token" {
  expect_repair_error("{} true", TrailingContent)
}

///|
test "reject duplicate plain keys" {
  expect_repair_error("{\"a\":1,\"a\":2}", DuplicateKey)
}

///|
test "reject duplicate decoded escape keys" {
  expect_repair_error("{\"a\":1,\"\\u0061\":2}", DuplicateKey)
}

///|
test "reject duplicate keys across quoting styles" {
  expect_repair_error("{a:1,'a':2}", DuplicateKey)
}

///|
test "96 nested truncated arrays close inside out" {
  let open = "[".repeat(96)
  expect_repaired(open + "1", open + "1" + "]".repeat(96))
}

///|
test "enforces a caller-supplied nesting limit before descending" {
  let limits : @json_repair.RepairLimits = {
    max_input: 128,
    max_depth: 3,
    max_edits: 8,
  }
  guard @json_repair.repair("[[[[1]]]]", limits~) is Err(error) else {
    fail("expected a depth failure")
  }
  assert_eq(error.kind, DepthLimit)
  assert_eq(error.position.offset, 3)
}

///|
test "depth clamps to a portable maximum" {
  let limits : @json_repair.RepairLimits = {
    max_input: 4096,
    max_depth: 1_000_000,
    max_edits: 1024,
  }
  let open = "[".repeat(257)
  guard @json_repair.repair(open, limits~) is Err(error) else {
    fail("expected a depth failure")
  }
  assert_eq(error.kind, DepthLimit)
  assert_eq(error.position.offset, 256)
}

///|
test "limits accept exact clean input size without spending edits" {
  let limits : @json_repair.RepairLimits = {
    max_input: 2,
    max_depth: 1,
    max_edits: 0,
  }
  guard @json_repair.repair("{}", limits~) is Ok(report) else {
    fail("exact limit should pass")
  }
  assert_true(report.edits.is_empty())
}

///|
test "limits reject the first unbudgeted repair edit" {
  let limits : @json_repair.RepairLimits = {
    max_input: 100,
    max_depth: 8,
    max_edits: 1,
  }
  guard @json_repair.repair("{a:True}", limits~) is Err(error) else {
    fail("expected an edit failure")
  }
  assert_eq(error.kind, EditLimit)
  assert_eq(error.position.offset, 3)
}

///|
test "limit counts Unicode in UTF16 code units" {
  let limits : @json_repair.RepairLimits = {
    max_input: 3,
    max_depth: 4,
    max_edits: 4,
  }
  guard @json_repair.repair("\"🧪\"", limits~) is Err(error) else {
    fail("emoji uses two code units")
  }
  assert_eq(error.kind, InputLimit)
}

///|
test "parsed AST decodes escapes and preserves exact decimal representation" {
  let input =
    #|{"escaped":"\uD83D\uDE04","number":9007199254740993}
  guard @json_repair.repair(input)
    is Ok(
      {
        value: {
          "escaped": String(emoji),
          "number": Number(_, repr=Some(repr)),
          ..
        },
        ..
      },
    ) else {
    fail("expected string and exact number nodes")
  }
  assert_eq(emoji, "😄")
  assert_eq(repr, "9007199254740993")
}

///|
test "every accepted prefix of a tool call produces strict idempotent JSON" {
  let input =
    #|{"tool":"search","args":{"tags":["moonbit","llm"],"floor":-4.02e+8,"open":false}}
  for end in 1..<=input.length() {
    let prefix = input[:end].to_owned()
    if @json_repair.repair(prefix) is Ok(report) {
      expect_repaired(prefix, report.json)
    }
  }
}

///|
test "numbered prose before a fenced tool call" {
  expect_repaired(
    "1. Here are the tool arguments:\n```json\n{amount:1}\n```",
    (
      #|{"amount":1}
    ),
  )
}

///|
test "numbered prose before a raw tool call" {
  expect_repaired(
    "12) The arguments are {amount:1}",
    (
      #|{"amount":1}
    ),
  )
}

///|
test "ignores brace placeholders in preceding prose" {
  let input = "Fill {placeholder} with these arguments:\n{amount:1}"
  let expected =
    #|{"amount":1}
  expect_repaired(input, expected)
}

///|
test "audit groups dangling member and preceding comma in one deletion" {
  let raw =
    #|{"a":1,/* pending */unfinished:
  guard @json_repair.repair(raw) is Ok(report) else {
    fail("expected a partial repair")
  }
  assert_eq(
    report.json,
    (
      #|{"a":1}
    ),
  )
  guard report.edits
    is [
      {
        kind: DropIncompleteMember,
        position: { offset: 6, .. },
        end_offset,
        ..
      },
      { kind: CloseObject, .. },
    ] else {
    fail("expected one deletion including the comma and one closure")
  }
  assert_eq(end_offset, raw.length())
}

///|
test "reject duplicate key even if its value is truncated" {
  expect_repair_error(
    (
      #|{"amount":0,"amount":
    ),
    DuplicateKey,
  )
}

///|
test "escaped high surrogate at EOF survives as literal text" {
  expect_repaired(
    (
      #|{"message":"\uD83D
    ),
    (
      #|{"message":"\\uD83D"}
    ),
  )
}

///|
test "truncated surrogate escape pair preserves both pieces as text" {
  expect_repaired(
    (
      #|["\uD83D\uDE
    ),
    (
      #|["\\uD83D\\uDE"]
    ),
  )
}
