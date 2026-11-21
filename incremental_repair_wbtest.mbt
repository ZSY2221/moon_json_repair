///|
priv struct CheckpointPrng {
  mut state : UInt32
}

///|
fn CheckpointPrng::pick(self : CheckpointPrng, limit : Int32) -> Int32 {
  let mut next = self.state
  next = next ^ (next << 13)
  next = next ^ (next >> 17)
  next = next ^ (next << 5)
  self.state = next
  (next % limit.reinterpret_as_uint()).reinterpret_as_int()
}

///|
fn assert_checkpoint_report(
  optimized : Result[RepairReport, RepairError],
  reference : Result[RepairReport, RepairError],
  prefix : String,
) -> Unit raise {
  assert_eq(optimized, reference, msg=prefix)
  if optimized is Ok(actual) && reference is Ok(expected) {
    assert_eq(actual.value.stringify(), expected.value.stringify(), msg=prefix)
  }
}

///|
fn check_checkpoint_sequence(
  source : String,
  policy : RepairPolicy,
  widths : CheckpointPrng?,
  schema : Json?,
) -> Unit raise {
  let current = RepairStream::with_policy(policy)
  let reference = RepairStream::with_uncached_policy(policy)
  let mut reconstructed = Json::null()
  let mut offset = 0
  while offset < source.length() {
    let width = match widths {
      Some(rng) => rng.pick(23) + 1
      None => 1
    }
    let end = (offset + width).min(source.length())
    let prefix = source.unsafe_substring(start=0, end~)
    let chunk = source.unsafe_substring(start=offset, end~)
    assert_eq(current.push(chunk), reference.push(chunk), msg=prefix)
    let preview = current.preview()
    let oracle = reference.preview()
    assert_checkpoint_report(preview, oracle, prefix)
    let frame = current.next_patches()
    let oracle_frame = reference.next_patches()
    assert_eq(frame, oracle_frame, msg=prefix)
    if frame is Ok(actual) && oracle_frame is Ok(expected) {
      assert_eq(
        @json.to_json(actual.patches).stringify(),
        @json.to_json(expected.patches).stringify(),
        msg=prefix,
      )
      assert_eq(actual.fields, expected.fields, msg=prefix)
      reconstructed = apply_json_patches(reconstructed, actual.patches[:]).unwrap()
      assert_true(
        patch_value_equal(reconstructed, actual.report.value, 0),
        msg=prefix,
      )
    }
    if schema is Some(schema) && preview is Ok(actual) && oracle is Ok(expected) {
      assert_eq(
        validate(actual.value, schema),
        validate(expected.value, schema),
        msg=prefix,
      )
      assert_eq(
        coerce_with_schema(actual.value, schema),
        coerce_with_schema(expected.value, schema),
        msg=prefix,
      )
    }
    offset = end
  }
  assert_checkpoint_report(current.finalize(), reference.finalize(), source)
  assert_checkpoint_report(
    current.preview(),
    repair_with_policy(source, policy),
    source,
  )
  assert_eq(current.scanned_units(), source.length())
}

///|
fn checkpoint_seed_input(rng : CheckpointPrng, mode : Int32) -> String {
  let count = rng.pick(8) + 1
  let pieces = [
    "for i in range(5):\\n\\tprint(\\\"hello\\\", i)\\n", "\\uD83D\\uDE00\\u002f\\\\src\\/main",
    "emoji 😀 and CR\\rLF\\n", "literal <think>notes</think> and a ~ slash /",
    "fn dump() { return \\'text\\' }",
  ]
  let body = StringBuilder()
  for _ in 0..<count {
    body.write_string(pieces[rng.pick(pieces.length())])
  }
  let body = body.to_string()
  let items = [
    "9007199254740993", "1.2300e-12", "true", "null", "{\"nested/~\":[\"value\",null,2]}",
    "[]", "{}",
  ]
  let object = StringBuilder()
  let array = StringBuilder()
  for index in 0..<count {
    if index > 0 {
      object.write_char(',')
      array.write_char(',')
    }
    let atom = items[rng.pick(items.length())]
    object.write_string(" \"path/~\{index}\" : \{atom} ")
    array.write_string(atom)
  }
  match mode {
    0 => "{\"code\":\"\{body}\"}"
    1 => "{\"outer\":[{\"inner\":{\"path\":\"main\",\"code\":\"\{body}\"}}]}"
    2 => "[\{array},[\"text\",[true,\"end\"]]]"
    3 => "{\{object},\"args\":{\"n\":\"3\",\"enabled\":\"true\"}}"
    4 => "{\{object},\"path/~0\":9007199254740993}"
    5 => "{\"empty\":[],\"code\":\"\{body}\",\"raw\":\"line\r\n\ttwo\"}"
    6 => "[\{array}, {unquoted:.3, quoted:'text', hex:0x20000000000001,},]"
    7 => "<ThInK>{\"draft\":\"\{body}\"}</think>{\{object}}"
    8 =>
      "<think><think>{\"draft\":\"unfinished\n</think>\n{'next':'\n</think>\n{\"answer\":\"'body\"}"
    9 => "prefix\n```json\n[ \{array} ]\n```"
    10 => "[\{array}, {\"bad\": undefined, \"text\":\"\\x4\"},]"
    _ => "{\{object},\"key\\u002f~unique\":\"\{body}\",\"tail\": [4e-12, -0]}"
  }
}

///|
fn run_checkpoint_oracle(mode : Int32) -> Unit raise {
  let rng : CheckpointPrng = {
    state: 2628071239U ^ (mode.reinterpret_as_uint() << 17),
  }
  let base = RepairOptions::default()
  let policy = { ..base, json5: mode == 6, }.with_ignore_think_blocks(
    mode is (7 | 8),
  )
  let schema : Json = {
    "type": "object",
    "properties": {
      "args": {
        "type": "object",
        "properties": {
          "n": { "type": "integer" },
          "enabled": { "type": "boolean" },
        },
      },
    },
  }
  for index in 0..<96 {
    let input = checkpoint_seed_input(rng, mode)
    let source = if index % 5 == 0 {
      input.unsafe_substring(start=0, end=rng.pick(input.length()) + 1)
    } else {
      input
    }
    check_checkpoint_sequence(
      source,
      policy,
      Some(rng),
      if mode == 3 {
        Some(schema)
      } else {
        None
      },
    )
  }
}

///|
test "checkpoint oracle 96 growing code strings" {
  run_checkpoint_oracle(0)
}

///|
test "checkpoint oracle 96 deep continuations" {
  run_checkpoint_oracle(1)
}

///|
test "checkpoint oracle 96 nested array appends" {
  run_checkpoint_oracle(2)
}

///|
test "checkpoint oracle 96 object additions with Schema and coercion" {
  run_checkpoint_oracle(3)
}

///|
test "checkpoint oracle 96 late duplicate keys" {
  run_checkpoint_oracle(4)
}

///|
test "checkpoint oracle 96 raw controls and mixed escapes" {
  run_checkpoint_oracle(5)
}

///|
test "checkpoint oracle 96 JSON5 fallback sequences" {
  run_checkpoint_oracle(6)
}

///|
test "checkpoint oracle 96 isolated think sequences" {
  run_checkpoint_oracle(7)
}

///|
test "checkpoint oracle 96 cross-line quote recoveries" {
  run_checkpoint_oracle(8)
}

///|
test "checkpoint oracle 96 fenced structure fallbacks" {
  run_checkpoint_oracle(9)
}

///|
test "checkpoint oracle 96 malformed literals and escapes" {
  run_checkpoint_oracle(10)
}

///|
test "checkpoint oracle 96 pointer escapes and exact numbers" {
  run_checkpoint_oracle(11)
}

///|
test "checkpoint matches one-shot repair at every raw and escaped UTF-16 cut" {
  let samples = [
    "{\"code\":\"line\\n\\t\\\"\\\\\\/\\r\\f\\b😀\\uD83D\\uDE00\\u2713\",\"/~/\":[null,true,false, -2.50e-1]}",
    "[[[\"abc\\uD83D\\uDE00\\u0001\"]],{\"first\":\"\\uD83D\\n\", \"second\":2 }]",
    "{\"literal\":\"<think>code</think>\",\"key😀\":true,\"x\\/y\\u007e\": \"\r\n😀\"}",
    "{\"new\": [ {\"partial\":9007199254740993 },1.23e+19, [] ], \"json\":{ \"arr\":[],\"more\":\"text\"}}",
    "{\"empty\":[] ,\r\n\"unfinished\"  :  ", "[1,2,\"text\", \r\n",
  ]
  for sample in samples {
    check_checkpoint_sequence(sample, RepairPolicy::default(), None, None)
  }
}

///|
test "checkpoint result mutations do not change later previews or patches" {
  let stream = RepairStream::new()
  stream
  .push("{\"object\":{\"x\":1},\"array\":[\"first\"],\"code\":\"a")
  .unwrap()
  let first = stream.next_patches().unwrap()
  guard first.report.value is Object(object) &&
    object.get("object") is Some(Object(nested)) &&
    object.get("array") is Some(Array(items)) else {
    abort("expected structured result")
  }
  nested["x"] = Json::null()
  items.push(Json::null())
  object["extra"] = Json::null()
  first.report.edits.clear()
  first.fields.clear()
  stream.push("b").unwrap()
  let second = stream.next_patches().unwrap()
  assert_eq(
    second.report.json,
    "{\"object\":{\"x\":1},\"array\":[\"first\"],\"code\":\"ab\"}",
  )
  assert_eq(second.patches, [
    { op: "replace", path: "/code", value: Some(Json::string("ab")), },
  ])
  assert_true(
    second.fields.any(field => field.pointer == "/object/x" && field.is_sealed),
  )
}

///|
test "checkpoint stays active at incomplete strict tokens and escape boundaries" {
  let stream = RepairStream::new()
  let parts = [
    "{\"a\": [2", ", {\"part", "\": ", "\"ab\\", "uD83D\\", "uDE00", "\\n", "\" }",
    "],", "\"b\": null", "}",
  ]
  for part in parts {
    stream.push(part).unwrap()
    guard stream.repair_checkpoint is Some(checkpoint) else {
      abort("missing checkpoint")
    }
    assert_true(checkpoint.snapshot(true) is Some(_), msg=part)
  }
  assert_eq(
    stream.finalize().unwrap().json,
    "{\"a\":[2,{\"part\":\"ab\\uD83D\\uDE00\\n\"}],\"b\":null}",
  )
}

///|
test "checkpoint duplicate fallback and reset keep exact error and patch history" {
  let stream = RepairStream::new()
  let before = "{\"key\":9007199254740993,"
  stream.push(before).unwrap()
  ignore(stream.next_patches().unwrap())
  stream.push("\"\\u006bey\":false}").unwrap()
  let input = before + "\"\\u006bey\":false}"
  assert_checkpoint_report(stream.preview(), repair(input), input)
  assert_true(stream.next_patches() is Err({ kind: DuplicateKey, .. }))
  stream.reset()
  assert_eq(stream.scanned_units(), 0)
  stream.push("[\"a\"").unwrap()
  assert_eq(stream.next_patches().unwrap().patches[0].path, "")
  stream.push(",\"b\"").unwrap()
  assert_eq(stream.next_patches().unwrap().patches, [
    { op: "add", path: "/1", value: Some(Json::string("b")), },
  ])
}

///|
test "write_file 10 KB and 50 KB benchmarks stay entirely on the checkpoint" {
  let head =
    #|{"tool":"write_file","args":{"path":"main.mbt","content":"
  let line =
    #|fn greet(name : String) -> Unit {\n  println(\"hello \" + name)\n}\n
  let tail =
    #|","id":9007199254740993}}
  for length in [10000, 50000] {
    let remaining = length - head.length() - tail.length()
    let input = head +
      line.repeat(remaining / line.length()) +
      " ".repeat(remaining % line.length()) +
      tail
    for width in [64, 256] {
      let stream = RepairStream::new()
      for at = 0; at < input.length(); at = at + width {
        let end = (at + width).min(input.length())
        stream.push(input.unsafe_substring(start=at, end~)).unwrap()
        guard stream.repair_checkpoint is Some(checkpoint) else {
          abort("write_file benchmark disabled the checkpoint")
        }
        assert_true(checkpoint.snapshot(true) is Some(_), msg="offset \{end}")
      }
      assert_eq(stream.preview().unwrap().json, input)
    }
  }
}

///|
test "reasoning policy reuses direct JSON and falls back for a following block" {
  let policy = RepairOptions::default().with_ignore_think_blocks(true)
  let stream = RepairStream::with_policy(policy)
  let json = "{\"text\":\"<think>inside the JSON string</think>\",\"n\":1}"
  stream.push(json).unwrap()
  assert_true(stream.repair_checkpoint is Some(_))
  assert_eq(stream.preview().unwrap().json, json)
  let trailing = "<think>remove this</think>"
  stream.push(trailing).unwrap()
  assert_true(stream.repair_checkpoint is None)
  assert_eq(stream.preview(), repair_with_policy(json + trailing, policy))
  stream.reset()
  assert_true(stream.repair_checkpoint is Some(_))
}

///|
test "checkpoint distinguishes committed trailing commas from speculative closes" {
  let policy = RepairPolicy::default()
  for input in ["[2,\r\n]", "{\"a\":[3,],\"b\":4,\t}"] {
    check_checkpoint_sequence(input, policy, None, None)
    let stream = RepairStream::with_policy(policy)
    stream.push(input).unwrap()
    assert_true(stream.repair_checkpoint is Some(_))
    assert_true(
      stream.preview().unwrap().edits.last()
      is Some({ kind: RemoveTrailingComma, .. }),
    )
  }
  let strict = {
    ..policy,
    options: {
      ..policy.options,
      limits: { ..policy.options.limits, max_edits: 0, },
    },
  }
  for input in ["[2,]", "{\"a\":[3,]}", "{\"b\":[{\"c\":\"grow"] {
    check_checkpoint_sequence(input, strict, None, None)
  }
}

///|
test "checkpoint matches precise fallback for invalid escape pairs and object keys" {
  let policy = RepairPolicy::default()
  for
    input in [
      "{\"code\":\"\\uD83D\\u0041\"}", "{\"code\":\"\\uDE00\\n\"}", "{\"key\"[]}",
    ] {
    let stream = RepairStream::with_policy(policy)
    stream.push(input).unwrap()
    assert_true(stream.repair_checkpoint is None, msg=input)
    check_checkpoint_sequence(input, policy, None, None)
  }
}

///|
test "checkpoint supports standalone atoms and repeated string snapshots" {
  let policy = RepairPolicy::default()
  for input in ["9007199254740993", " 1.02e+16\t", "null", "true", "false"] {
    check_checkpoint_sequence(input, policy, None, None)
  }
  let stream = RepairStream::new()
  stream.push("{\"text\":\"repeat").unwrap()
  let initial = stream.next_patches().unwrap()
  stream.push("").unwrap()
  let repeated = stream.next_patches().unwrap()
  assert_eq(repeated.report, initial.report)
  assert_true(repeated.patches.is_empty())
}

///|
test "checkpoint empty snapshot can resume on the first argument frame" {
  let stream = RepairStream::new()
  assert_true(stream.preview() is Err({ kind: EmptyInput, .. }))
  assert_true(stream.next_patches() is Err({ kind: EmptyInput, .. }))
  let input =
    #|{"argument":"ready"
  stream.push(input).unwrap()
  let frame = stream.next_patches().unwrap()
  assert_eq(frame.patches.length(), 1)
  assert_eq(frame.patches[0].path, "")
  assert_eq(frame.report.json, "{\"argument\":\"ready\"}")
}

///|
test "checkpoint input overflow preserves the accepted UTF-16 prefix and Patch baseline" {
  let input = "{\"text\":\"😀\"}"
  let limits = { ..RepairLimits::default(), max_input: input.length(), }
  let stream = RepairStream::new(limits~)
  stream.push(input).unwrap()
  let prior = stream.next_patches().unwrap()
  let limit = stream.push(" ").unwrap_err()
  assert_eq(limit.kind, InputLimit)
  assert_eq(limit.position.offset, input.length())
  assert_eq(stream.scanned_units(), input.length())
  let current = stream.next_patches().unwrap()
  assert_eq(current.report, prior.report)
  assert_eq(current.fields, prior.fields)
  assert_true(current.patches.is_empty())
}

///|
test "checkpoint stops at the depth limit and preserves the reference error position" {
  let policy = RepairPolicy::default()
  let policy = {
    ..policy,
    options: {
      ..policy.options,
      limits: { ..policy.options.limits, max_depth: 3, },
    },
  }
  let stream = RepairStream::with_policy(policy)
  stream.push("[[[0").unwrap()
  assert_true(stream.repair_checkpoint is Some(_))
  assert_eq(stream.preview().unwrap().json, "[[[0]]]")
  stream.push(",[").unwrap()
  assert_true(stream.repair_checkpoint is None)
  let input = "[[[0,["
  let expected = repair_with_policy(input, policy).unwrap_err()
  assert_eq(expected.kind, DepthLimit)
  assert_eq(stream.preview(), Err(expected))
  assert_eq(stream.next_patches(), Err(expected))
}

///|
test "checkpoint maintains sealed escaped keys when a root object grows" {
  let stream = RepairStream::new()
  stream.push("{\"epoch\":\"A\"").unwrap()
  ignore(stream.next_patches().unwrap())
  stream.push(",\"id~\\u002fkey\":\"B\"").unwrap()
  let frame = stream.next_patches().unwrap()
  assert_eq(frame.patches, [
    { op: "add", path: "/id~0~1key", value: Some(Json::string("B")), },
  ])
  assert_eq(frame.fields, [
    { pointer: "/epoch", is_sealed: true, },
    { pointer: "/id~0~1key", is_sealed: true, },
    { pointer: "", is_sealed: false, },
  ])
}

///|
test "checkpoint emits exact numeric lexemes for an appended root array member" {
  let stream = RepairStream::new()
  stream.push("[0,").unwrap()
  ignore(stream.next_patches().unwrap())
  stream.push("9007199254740993,").unwrap()
  let frame = stream.next_patches().unwrap()
  assert_eq(frame.patches.length(), 1)
  assert_eq(frame.patches[0].path, "/1")
  assert_eq(frame.patches[0].op, "add")
  assert_eq(frame.patches[0].value.unwrap().stringify(), "9007199254740993")
}

///|
test "checkpoint accepts a low surrogate that arrives after an invalid preview" {
  let stream = RepairStream::new()
  let emoji = "😀"
  let high = emoji.unsafe_substring(start=0, end=1)
  let low = emoji.unsafe_substring(start=1, end=2)
  stream.push("{\"text\":\"" + high).unwrap()
  assert_true(stream.preview() is Err({ kind: InvalidUnicode, .. }))
  assert_true(stream.next_patches() is Err({ kind: InvalidUnicode, .. }))
  stream.push(low + "\"}").unwrap()
  let frame = stream.next_patches().unwrap()
  assert_eq(frame.report.json, "{\"text\":\"😀\"}")
  assert_eq(frame.patches[0].path, "")
  assert_true(frame.report.edits.is_empty())
}

///|
test "checkpoint preserves original CRLF and escape spans across an emoji" {
  let stream = RepairStream::new()
  let prefix = "{\"text\":\"😀\r"
  stream.push(prefix).unwrap()
  stream.push("\n\\u").unwrap()
  let input = prefix + "\n\\u"
  let report = stream.preview().unwrap()
  assert_eq(report, repair(input).unwrap())
  assert_eq(report.edits[0].position, { offset: 11, line: 1, column: 12, })
  assert_eq(report.edits[1].position, { offset: 12, line: 2, column: 1, })
  assert_eq(report.edits[2].position, { offset: 13, line: 2, column: 1, })
  assert_eq(report.edits[2].kind, EscapeBackslash)
}

///|
test "checkpoint root scalar extensions keep decimal spelling exactly" {
  let stream = RepairStream::new()
  stream.push("1.2300").unwrap()
  let initial = stream.next_patches().unwrap()
  assert_eq(initial.patches[0].value.unwrap().stringify(), "1.2300")
  stream.push("e-12").unwrap()
  let frame = stream.next_patches().unwrap()
  assert_eq(frame.report.json, "1.2300e-12")
  assert_eq(frame.patches[0].value.unwrap().stringify(), "1.2300e-12")
  assert_false(frame.fields[0].is_sealed)
}

///|
test "checkpoint respects the string and container edit budget across attempts" {
  let limits = { ..RepairLimits::default(), max_edits: 1, }
  let stream = RepairStream::new(limits~)
  stream.push("{\"value\":\"a").unwrap()
  assert_true(stream.preview() is Err({ kind: EditLimit, .. }))
  assert_true(stream.next_patches() is Err({ kind: EditLimit, .. }))
  stream.push("\"").unwrap()
  let frame = stream.next_patches().unwrap()
  assert_eq(frame.report.json, "{\"value\":\"a\"}")
  assert_eq(frame.report.edits.map(edit => edit.kind), [CloseObject])
  assert_eq(frame.patches[0].path, "")
}

///|
test "checkpoint finalized input can reset without retaining a previous patch anchor" {
  let stream = RepairStream::new()
  stream.push("{\"old\":[1,2").unwrap()
  ignore(stream.next_patches().unwrap())
  ignore(stream.finalize().unwrap())
  assert_true(stream.push("]}") is Err({ kind: UnexpectedToken, .. }))
  stream.reset()
  assert_false(stream.status().finalized)
  assert_eq(stream.scanned_units(), 0)
  stream.push("{\"new\":true}").unwrap()
  let frame = stream.next_patches().unwrap()
  assert_eq(frame.patches.length(), 1)
  assert_eq(frame.patches[0].path, "")
  assert_eq(frame.report.json, "{\"new\":true}")
}

///|
test "checkpoint refuses a speculative escape tail when its wrapper is not a single value" {
  // The producer normally accepts only incomplete escape text. Supply a
  // malformed internal tail to verify the snapshot's defensive fallback.
  let checkpoint = RepairCheckpoint::new(RepairLimits::default())
  assert_true(checkpoint.feed("\"kept\\"[:]))
  guard checkpoint.token is QuotedToken(quoted) else {
    abort("expected an incomplete quoted token")
  }
  quoted.raw_escape.write_string("n\" 0")
  assert_true(quoted.escape_tail() is None)
  assert_true(checkpoint.snapshot(true) is None)
}

///|
test "checkpoint rejects a committed-root hint for a non-container result" {
  let checkpoint = RepairCheckpoint::new(RepairLimits::default())
  assert_true(checkpoint.feed("[0,"[:]))
  let previous = checkpoint.snapshot(true).unwrap()
  // Only an open container normally issues this hint. If a future producer
  // violates the contract, the general diff still replaces the root value.
  let report = repair("9007199254740993").unwrap()
  let next = { ..previous, report, }
  let patches = checkpoint_patches(
    previous.report.value,
    previous.hint,
    next,
    checkpoint,
  )
  assert_eq(patches.length(), 1)
  assert_eq(patches[0].op, "replace")
  assert_eq(patches[0].path, "")
  assert_eq(patches[0].value.unwrap().stringify(), report.json)
}
