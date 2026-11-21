///|
test "CLI preserves default switches and stdin" {
  let flags = @cli.parse_args(["-"])
  assert_eq(flags.input, None)
  assert_eq(flags.schema, None)
  assert_false(flags.ndjson)
  assert_false(flags.extract_all)
  assert_false(flags.ignore_think)
  assert_false(flags.coerce)
  assert_false(flags.retry_prompt)
  assert_false(flags.strict_exit)
}

///|
test "CLI parses all pipe flags and the schema path" {
  let flags = @cli.parse_args([
    "--ndjson", "--extract-all", "--ignore-think", "--coerce", "--retry-prompt",
    "--strict-exit", "--schema", "schema.json", "source.ndjson",
  ])
  assert_eq(flags.input, Some("source.ndjson"))
  assert_eq(flags.schema, Some("schema.json"))
  assert_true(flags.ndjson)
  assert_true(flags.extract_all)
  assert_true(flags.ignore_think)
  assert_true(flags.coerce)
  assert_true(flags.retry_prompt)
  assert_true(flags.strict_exit)
}

///|
test "CLI end-of-options keeps flag-like paths positional" {
  let flags = @cli.parse_args(["--ndjson", "--", "--extract-all"])
  assert_eq(flags.input, Some("--extract-all"))
  assert_true(flags.ndjson)
  assert_false(flags.extract_all)
}

///|
test "CLI usage mistakes have exit status 2" {
  for
    args in [
      ["--schema"],
      ["--schema", "a", "--schema", "b"],
      ["--coerce"],
      ["--retry-prompt"],
      ["--unexpected"],
      ["a", "b"],
    ] {
    try @cli.parse_args(args[:]) catch {
      @cli.CliFailure(error, status) => {
        assert_true(error is { "kind": "usage", .. })
        assert_eq(status, 2)
      }
    } noraise {
      _ => fail("invalid CLI args accepted")
    }
  }
}

///|
test "CLI parses strict schema text with exact numeric values" {
  let schema = @cli.parse_schema("{\"minimum\":9007199254740993}")
  assert_eq(schema.stringify(), "{\"minimum\":9007199254740993}")
  try @cli.parse_schema("{\"minimum\":1,\"minimum\":2}") catch {
    @cli.CliFailure(error, status) => {
      assert_true(error is { "kind": "schema_parse", .. })
      assert_eq(status, 1)
    }
  } noraise {
    _ => fail("duplicate keys accepted in schema")
  }
}

///|
test "CLI default output retains the exact integer and legacy envelope" {
  let flags = @cli.parse_args([])
  let input = @cli.prepare_input("{\"n\":9007199254740993", flags).unwrap()
  let result = @cli.present(input, None, flags)
  let report = result.report()
  assert_eq(result.status, 0)
  assert_true(
    report is { "json": "{\"n\":9007199254740993}", "schema": Null, .. },
  )
  assert_eq(result.fields.length(), 4)
  assert_true(report.stringify().contains("\"value\":{\"n\":9007199254740993}"))
}

///|
test "CLI extraction reports both exact spans" {
  let flags = @cli.parse_args(["--extract-all"])
  let input = @cli.prepare_input("{\"x\":1}{\"x\":2}", flags).unwrap()
  let output = @cli.present(input, None, flags)
  assert_eq(output.status, 0)
  assert_true(
    output.report()
    is {
      "blocks": [
        {
          "start": { "offset": 0, .. },
          "end": { "offset": 7, .. },
          "json": "{\"x\":1}",
          ..
        },
        {
          "start": { "offset": 7, .. },
          "end": { "offset": 14, .. },
          "json": "{\"x\":2}",
          ..
        },
      ],
      ..
    },
  )
  assert_true(
    @cli.prepare_input("only prose", flags) is Err({ "kind": "no_blocks", .. }),
  )
}

///|
test "CLI forwards ignore-think without enabling it by default" {
  let raw = "<THINK>{\"draft\":1}</tHiNk>{\"actual\":2"
  let defaults = @cli.parse_args(["--extract-all"])
  let default_input = @cli.prepare_input(raw, defaults).unwrap()
  let default_output = @cli.present(default_input, None, defaults)
  assert_true(default_output.report() is { "blocks": [_, _], .. })
  let flags = @cli.parse_args(["--extract-all", "--ignore-think"])
  let input = @cli.prepare_input(raw, flags).unwrap()
  let output = @cli.present(input, None, flags)
  assert_true(
    output.report() is { "blocks": [{ "json": "{\"actual\":2}", .. }], .. },
  )
}

///|
test "CLI schema coercion preserves a quoted wide integer exactly" {
  let flags = @cli.parse_args([
    "--schema", "schema", "--coerce", "--retry-prompt",
  ])
  let schema = @cli.parse_schema(
    "{\"properties\":{\"n\":{\"type\":\"integer\"}}}",
  )
  let input = @cli.prepare_input("{\"n\":\"9007199254740993\"}", flags).unwrap()
  let result = @cli.present(input, Some(schema), flags)
  assert_eq(result.status, 0)
  assert_true(
    result.report()
    is {
      "json": "{\"n\":9007199254740993}",
      "schema": { "valid": true, .. },
      "coercions": [{ "kind": "string_to_number", "path": "$.n", .. }],
      "retry_prompt": "",
      ..
    },
  )
  assert_true(
    result.report().stringify().contains("\"value\":{\"n\":9007199254740993}"),
  )
}

///|
test "CLI extraction's schema status reflects any rejected block" {
  let flags = @cli.parse_args([
    "--extract-all", "--schema", "schema", "--retry-prompt",
  ])
  let schema = @cli.parse_schema("{\"properties\":{\"n\":{\"minimum\":0}}}")
  let input = @cli.prepare_input("{\"n\":1}{\"n\":-1}", flags).unwrap()
  let result = @cli.present(input, Some(schema), flags)
  assert_eq(result.status, 3)
  guard result.report()
    is {
      "blocks": [
        { "schema": { "valid": true, .. }, "retry_prompt": "", .. },
        {
          "schema": { "valid": false, "errors": [{ "path": "$.n", .. }], .. },
          "retry_prompt": String(prompt),
          ..
        },
      ],
      ..
    } else {
    fail("missing extracted schema reports")
  }
  assert_true(prompt.contains("$.n"))
}

///|
test "CLI line decoder joins split UTF-8 and CRLF boundaries" {
  let source = @cli.BatchLines::new(max_chars=20)
  let (offset, partial) = source.next(b"{\"x\":\"\xF0\x9F"[:], 0)
  assert_eq(offset, 8)
  assert_true(partial is None)
  let (offset, partial) = source.next(b"\x8C\x99\"}\r"[:], 0)
  assert_eq(offset, 5)
  assert_true(partial is None)
  let batch = b"\n[]\n"
  let (offset, first) = source.next(batch[:], 0)
  assert_eq(offset, 1)
  assert_eq(first.unwrap().line, 1L)
  assert_eq(first.unwrap().input, Ok("{\"x\":\"🌙\"}"))
  let (offset, second) = source.next(batch[:], offset)
  assert_eq(offset, 4)
  assert_eq(second.unwrap().line, 2L)
  assert_eq(second.unwrap().input, Ok("[]"))
  assert_true(source.finish() is None)
}

///|
test "CLI line decoder recovers from invalid UTF-8 mid-batch" {
  let source = @cli.BatchLines::new(max_chars=20)
  let batch = b"\xFF\n{}"
  let (offset, first) = source.next(batch[:], 0)
  assert_true(first.unwrap().input is Err({ "kind": "invalid_utf8", .. }))
  let (_, next) = source.next(batch[:], offset)
  assert_true(next is None)
  let last = source.finish().unwrap()
  assert_eq(last.line, 2L)
  assert_eq(last.input, Ok("{}"))
  assert_true(source.finish() is None)
}

///|
test "CLI line decoder discards the rest of an oversized multi-chunk line" {
  let source = @cli.BatchLines::new(max_chars=2)
  let (_, partial) = source.next(b"1234567890"[:], 0)
  assert_true(partial is None)
  let batch = b"tail\n[]\n"
  let (offset, first) = source.next(batch[:], 0)
  assert_true(first.unwrap().input is Err({ "kind": "input_limit", .. }))
  let (_, second) = source.next(batch[:], offset)
  assert_eq(second.unwrap().input, Ok("[]"))
}

///|
test "CLI line decoder enforces UTF-16 limits separately from bytes" {
  let source = @cli.BatchLines::new(max_chars=2)
  let (_, record) = source.next(b"abc\n"[:], 0)
  assert_true(record.unwrap().input is Err({ "kind": "input_limit", .. }))
}

///|
test "CLI emits a structured blank-line rejection and retains line numbers" {
  let flags = @cli.parse_args(["--ndjson"])
  let source = @cli.BatchLines::new(max_chars=20)
  let batch = b"\n{}\n"
  let (offset, first) = source.next(batch[:], 0)
  let record = first.unwrap()
  let failure = @cli.process_line(record, None, flags)
  assert_eq(failure.status, 1)
  assert_true(
    failure.for_line(record.line)
    is {
      "line": 1,
      "ok": false,
      "status": 1,
      "error": { "kind": "empty_input", .. },
      ..
    },
  )
  let (_, second) = source.next(batch[:], offset)
  let record = second.unwrap()
  assert_true(
    @cli.process_line(record, None, flags).for_line(record.line)
    is { "line": 2, "ok": true, "status": 0, "json": "{}", .. },
  )
}

///|
test "CLI strict batch exit gives record rejection precedence over schema failure" {
  let loose = @cli.parse_args(["--ndjson"])
  let strict = @cli.parse_args(["--ndjson", "--strict-exit"])
  assert_eq(@cli.batch_exit_status(loose, 3), 0)
  assert_eq(@cli.batch_exit_status(loose, 1), 0)
  assert_eq(@cli.batch_exit_status(strict, 3), 3)
  assert_eq(@cli.batch_exit_status(strict, 1), 1)
  assert_eq(@cli.batch_exit_status(strict, 0), 0)
  assert_eq(@cli.merge_status(3, 1), 1)
  assert_eq(@cli.merge_status(1, 3), 1)
  assert_eq(@cli.merge_status(0, 3), 3)
  assert_eq(@cli.merge_status(3, 0), 3)
}
