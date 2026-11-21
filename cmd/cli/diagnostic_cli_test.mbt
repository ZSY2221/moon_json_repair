///|
test "CLI diagnostic presentation defaults to an unchanged JSON report" {
  let (options, format) = @cli.parse_args_with_diagnostics([])
  assert_true(format is Structured)
  let report = @cli.prepare_input("{a:1,}", options).unwrap()
  assert_false(
    @cli.present(report, None, options)
    .report()
    .stringify()
    .contains("diagnostic"),
  )
}

///|
test "CLI pretty format preserves path and remaining flags" {
  let (options, format) = @cli.parse_args_with_diagnostics([
    "--diagnostic-format", "pretty", "--ndjson", "--schema", "schema.json", "-",
  ])
  assert_true(format is Pretty)
  assert_true(options.ndjson)
  assert_eq(options.input, None)
  assert_eq(options.schema, Some("schema.json"))
}

///|
test "CLI ANSI and explicit JSON modes are accepted" {
  let (_, ansi) = @cli.parse_args_with_diagnostics([
    "--diagnostic-format", "ansi",
  ])
  let (_, json) = @cli.parse_args_with_diagnostics([
    "--diagnostic-format", "json", "--sse",
  ])
  assert_true(ansi is Ansi)
  assert_true(json is Structured)
}

///|
test "CLI malformed or duplicate diagnostic format flags are usage errors" {
  for
    args in [
      ["--diagnostic-format"],
      ["--diagnostic-format", "unknown"],
      ["--diagnostic-format", "pretty", "--diagnostic-format", "ansi"],
      ["--sse", "--diagnostic-format", "pretty"],
      [
        "--mcp-guard", "--tool-schemas", "tools.json", "--diagnostic-format", "ansi",
      ],
    ] {
    try @cli.parse_args_with_diagnostics(args[:]) catch {
      @cli.CliFailure(error, status) => {
        assert_true(error is { "kind": "usage", .. })
        assert_eq(status, 2)
      }
    } noraise {
      _ => fail("invalid diagnostic options accepted")
    }
  }
}

///|
test "CLI diagnostic option is positional after the end-of-options token" {
  let (options, format) = @cli.parse_args_with_diagnostics([
    "--", "--diagnostic-format",
  ])
  assert_eq(options.input, Some("--diagnostic-format"))
  assert_true(format is Structured)
}

///|
test "CLI pretty repair errors report the original UTF-16 column" {
  let (options, format) = @cli.parse_args_with_diagnostics([
    "--diagnostic-format", "pretty",
  ])
  let source = "{\r\n  \"文😀\": @\r\n}"
  guard! @cli.prepare_input_with_diagnostics(source, options, format)
    is Err({ "kind": "unexpected_token", "diagnostic": String(diagnostic), .. })
  assert_true(diagnostic.contains(" --> 2:10 (UTF-16)"))
  assert_true(diagnostic.contains("2 |   \"文😀\": @"))
  assert_false(diagnostic.contains("\u001b"))
}

///|
test "CLI ANSI audit and schema diagnostic keep the exact integer" {
  let (options, format) = @cli.parse_args_with_diagnostics([
    "--diagnostic-format", "ansi",
  ])
  let source = "{n:9007199254740993,}"
  let input = @cli.prepare_input_with_diagnostics(source, options, format).unwrap()
  let schema = @cli.parse_schema(
    "{\"properties\":{\"n\":{\"maximum\":9007199254740992}}}",
  )
  let outcome = @cli.present_with_diagnostics(
    input,
    Some(schema),
    options,
    source,
    format,
  )
  assert_eq(outcome.status, 3)
  guard! outcome.report()
    is {
      "repair_diagnostic": String(audit),
      "schema_diagnostic": String(diagnostic),
      "json": "{\"n\":9007199254740993}",
      ..
    }
  assert_true(audit.contains("\u001b[1;36medit[quote_key]"))
  assert_true(diagnostic.contains("\u001b[1;31merror[maximum]"))
  assert_true(diagnostic.contains("$.n"))
  assert_true(diagnostic.contains("9007199254740993"))
}

///|
test "CLI invalid schema rule uses the original definition text" {
  let (options, format) = @cli.parse_args_with_diagnostics([
    "--diagnostic-format", "pretty",
  ])
  let source = "42"
  let schema_text = "{\r\n  \"type\": \"unknown\"\r\n}"
  let schema = @cli.parse_schema(schema_text)
  let prepared = @cli.prepare_input(source, options).unwrap()
  let outcome = @cli.present_with_diagnostics(
    prepared,
    Some(schema),
    options,
    source,
    format,
    schema_source=Some(schema_text),
  )
  guard! outcome.report() is { "schema_diagnostic": String(text), .. }
  assert_eq(outcome.status, 3)
  assert_true(text.contains(" --> 2:11 (UTF-16) $schema.type"))
  assert_true(text.contains("2 |   \"type\": \"unknown\""))
}

///|
test "CLI extracted audit positions refer to the entire reply" {
  let (options, format) = @cli.parse_args_with_diagnostics([
    "--extract-all", "--diagnostic-format", "pretty",
  ])
  let source = "prefix\n{a:1}\n{b:2}"
  let input = @cli.prepare_input_with_diagnostics(source, options, format).unwrap()
  let outcome = @cli.present_with_diagnostics(
    input,
    None,
    options,
    source,
    format,
  )
  guard! outcome.report()
    is {
      "blocks": [
        { "repair_diagnostic": String(first), .. },
        { "repair_diagnostic": String(second), .. },
      ],
      ..
    }
  assert_true(first.contains(" --> 2:2 (UTF-16)"))
  assert_true(second.contains(" --> 3:2 (UTF-16)"))
}

///|
test "CLI diagnostic NDJSON records preserve transport line number and status" {
  let (options, format) = @cli.parse_args_with_diagnostics([
    "--ndjson", "--diagnostic-format", "pretty",
  ])
  let lines = @cli.BatchLines::new(max_chars=80)
  let (_, record) = lines.next(b"{\"n\":@}\n"[:], 0)
  let record = record.unwrap()
  let outcome = @cli.process_line_with_diagnostics(
    record,
    None,
    options,
    format,
  )
  assert_eq(outcome.status, 1)
  guard! outcome.for_line(record.line)
    is {
      "line": 1,
      "ok": false,
      "status": 1,
      "error": { "diagnostic": String(text), .. },
      ..
    }
  assert_true(text.contains("error[unexpected_token]"))
  assert_true(text.contains(" --> 1:6 (UTF-16)"))
}
