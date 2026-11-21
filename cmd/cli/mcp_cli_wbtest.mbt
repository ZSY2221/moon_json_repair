///|
let cli_mcp_schemas : String =
  #|{"write_file":{"type":"object","properties":{"n":{"type":"integer","minimum":0}},"required":["n"]},"read_file":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}

///|
fn cli_mcp_record(source : String) -> BatchLine {
  { line: 1L, input: Ok(source), }
}

///|
fn cli_mcp_check(
  source : String,
  extra : Array[String],
) -> (String?, Int32) raise {
  let arguments = ["--mcp-guard", "--tool-schemas", "tools.json"]
  for argument in extra {
    arguments.push(argument)
  }
  process_mcp_line(
    cli_mcp_record(source),
    parse_tool_schemas(cli_mcp_schemas),
    parse_args(arguments[:]),
  )
}

///|
fn cli_mcp_read(text : String?) -> Json raise {
  @json.parse(text.unwrap()[:], preserve_number_repr=true)
}

///|
fn assert_mcp_cli_usage(args : ArrayView[String]) -> Unit raise {
  try parse_args(args) catch {
    CliFailure(error, status) => {
      assert_eq(status, 2)
      assert_true(error is { "kind": "usage", .. })
    }
  } noraise {
    _ => fail("invalid MCP guard arguments were accepted")
  }
}

///|
test "CLI MCP guard keeps legacy defaults" {
  let options = parse_args([])
  assert_false(options.mcp_guard)
  assert_eq(options.tool_schemas, None)
  assert_false(options.json5)
}

///|
test "CLI MCP guard parses registry, modifiers, and file path" {
  let options = parse_args([
    "--ignore-think", "--tool-schemas", "tools.json", "--strict-exit", "--mcp-guard",
    "--coerce", "--json5", "input.ndjson",
  ])
  assert_true(options.mcp_guard)
  assert_true(options.coerce)
  assert_true(options.json5)
  assert_true(options.ignore_think)
  assert_true(options.strict_exit)
  assert_eq(options.tool_schemas, Some("tools.json"))
  assert_eq(options.input, Some("input.ndjson"))
}

///|
test "CLI MCP guard alone requires a registry" {
  assert_mcp_cli_usage(["--mcp-guard"])
}

///|
test "CLI tool registry requires guard mode" {
  assert_mcp_cli_usage(["--tool-schemas", "tools.json"])
}

///|
test "CLI tool registry requires a single file path" {
  assert_mcp_cli_usage(["--mcp-guard", "--tool-schemas"])
  assert_mcp_cli_usage([
    "--mcp-guard", "--tool-schemas", "tools.json", "--tool-schemas", "more.json",
  ])
}

///|
test "CLI MCP guard rejects conflicting modes and options" {
  for
    option in [
      "--sse", "--ndjson", "--extract-all", "--retry-prompt", "--emit-patches",
    ] {
    assert_mcp_cli_usage(["--mcp-guard", "--tool-schemas", "tools.json", option])
  }
  assert_mcp_cli_usage([
    "--mcp-guard", "--tool-schemas", "tools.json", "--schema", "schema.json",
  ])
}

///|
test "CLI MCP option processing respects end of switches" {
  let options = parse_args([
    "--mcp-guard", "--tool-schemas", "tools.json", "--", "--sse",
  ])
  assert_true(options.mcp_guard)
  assert_false(options.sse)
  assert_eq(options.input, Some("--sse"))
}

///|
test "CLI MCP registry detects malformed JSON at startup" {
  let text = "{\"read_file\":"
  try parse_tool_schemas(text) catch {
    CliFailure(error, status) => {
      assert_eq(status, 1)
      assert_true(error is { "kind": "schema_parse", .. })
    }
  } noraise {
    _ => fail("invalid JSON was accepted as a tool schema registry")
  }
}

///|
test "CLI MCP registry requires a tool-to-schema object" {
  try parse_tool_schemas("[]") catch {
    CliFailure(error, status) => {
      assert_eq(status, 1)
      assert_true(error is { "kind": "tool_schemas", .. })
    }
  } noraise {
    _ => fail("array was accepted as a tool schema registry")
  }
}

///|
test "CLI MCP registry rejects duplicate tool names before reading frames" {
  let text =
    #|{"read_file":{},"read_file":{}}
  try parse_tool_schemas(text) catch {
    CliFailure(error, status) => {
      assert_eq(status, 1)
      assert_true(error is { "kind": "schema_parse", .. })
    }
  } noraise {
    _ => fail("duplicate names were accepted in a tool schema registry")
  }
}

///|
test "CLI MCP forwards exact tool requests with wide numbers" {
  let wire =
    #|{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"write_file","arguments":{"n":9007199254740993}}}
  let source = "  " + wire + " \t"
  assert_eq(cli_mcp_check(source, []), (Some(source), 0))
}

///|
test "CLI MCP repairs the JSON-RPC envelope and unfinished arguments" {
  let source =
    #|{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"write_file","arguments":{"n":2
  let (line, status) = cli_mcp_check(source, [])
  assert_eq(status, 0)
  assert_true(
    cli_mcp_read(line)
    is {
      "jsonrpc": "2.0",
      "method": "tools/call",
      "params": { "name": "write_file", "arguments": { "n": 2, .. }, .. },
      ..
    },
  )
  assert_true(line.unwrap().contains("\"id\":9007199254740993"))
}

///|
test "CLI MCP redecodes stringified arguments and coerces exact integers" {
  let source =
    #|{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"write_file","arguments":"{\"n\":\"9007199254740993\""}
  let (line, status) = cli_mcp_check(source, ["--coerce"])
  assert_eq(status, 0)
  assert_true(line.unwrap().contains("\"arguments\":{\"n\":9007199254740993}"))
  assert_true(line.unwrap().contains("\"id\":9007199254740993"))
}

///|
test "CLI MCP applies independent schema to each routed tool" {
  let source =
    #|{"jsonrpc":"2.0","id":"read","method":"tools/call","params":{"name":"read_file","arguments":{"path":"lib/test.mbt"}}}
  assert_eq(cli_mcp_check(source, []), (Some(source), 0))
}

///|
test "CLI MCP emits Invalid params with original id and exact validation path" {
  let source =
    #|{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"write_file","arguments":{"n":-1}}}
  let (line, status) = cli_mcp_check(source, [])
  assert_eq(status, 3)
  assert_true(
    cli_mcp_read(line)
    is {
      "jsonrpc": "2.0",
      "error": {
        "code": -32602,
        "data": {
          "issues": [{ "path": "$.params.arguments.n", .. }],
          "retry_prompt": String(_),
          ..
        },
        ..
      },
      ..
    },
  )
  assert_true(line.unwrap().contains("\"id\":9007199254740993"))
}

///|
test "CLI MCP does not forward calls to unregistered tools" {
  let source =
    #|{"jsonrpc":"2.0","id":"unknown","method":"tools/call","params":{"name":"unknown","arguments":{}}}
  let (line, status) = cli_mcp_check(source, [])
  assert_eq(status, 3)
  assert_true(
    cli_mcp_read(line)
    is { "id": "unknown", "error": { "code": -32602, .. }, .. },
  )
}

///|
test "CLI MCP does not emit a response to refused notifications" {
  let source =
    #|{"jsonrpc":"2.0","method":"tools/call","params":{"name":"write_file","arguments":{"n":1}}}
  assert_eq(cli_mcp_check(source, []), (None, 3))
}

///|
test "CLI MCP passes through non-tool request bytes" {
  let source =
    #| { "id": 9007199254740993, "method" : "tools/list", "jsonrpc" : "2.0" }
  assert_eq(cli_mcp_check(source, []), (Some(source), 0))
}

///|
test "CLI MCP passes through ordinary notifications and responses" {
  let notification =
    #|{"jsonrpc":"2.0","method":"notifications/initialized"}
  let response =
    #|{"jsonrpc":"2.0","id":"read","result":{"content":[]}}
  assert_eq(cli_mcp_check(notification, []), (Some(notification), 0))
  assert_eq(cli_mcp_check(response, []), (Some(response), 0))
}

///|
test "CLI MCP reports irreparable input and preserves JSON-RPC output boundaries" {
  let (line, status) = cli_mcp_check("not json", [])
  assert_eq(status, 1)
  assert_true(
    cli_mcp_read(line) is { "id": Null, "error": { "code": -32700, .. }, .. },
  )
}

///|
test "CLI MCP reports invalid requests separately from malformed JSON" {
  let text =
    #|{"jsonrpc":"1.0","id":"bad","method":"tools/list"}
  let (line, status) = cli_mcp_check(text, [])
  assert_eq(status, 1)
  assert_true(cli_mcp_read(line) is { "error": { "code": -32600, .. }, .. })
}

///|
test "CLI MCP preserves transport fault data in a JSON-RPC error" {
  let options = parse_args(["--mcp-guard", "--tool-schemas", "tools.json"])
  let (line, status) = process_mcp_line(
    { line: 9L, input: Err(error_json("invalid_utf8", "invalid text")), },
    parse_tool_schemas(cli_mcp_schemas),
    options,
  )
  assert_eq(status, 1)
  assert_true(
    cli_mcp_read(line)
    is {
      "id": Null,
      "error": { "code": -32700, "data": { "kind": "invalid_utf8", .. }, .. },
      ..
    },
  )
}

///|
test "CLI MCP applies the JSON5 and ignore-think policy to outer inputs" {
  let source =
    #|<think>{"draft":true}</think>{"jsonrpc":"2.0","id":"wide","method":"tools/call","params":{"name":"write_file","arguments":{"n":0x20000000000001}}}
  let (line, status) = cli_mcp_check(source, ["--json5", "--ignore-think"])
  assert_eq(status, 0)
  assert_true(line.unwrap().contains("\"arguments\":{\"n\":9007199254740993}"))
}

///|
test "CLI JSON5 opt-in also applies to the legacy repair mode" {
  let flags = parse_args(["--json5"])
  let input = prepare_input("{n:0x20000000000001}", flags).unwrap()
  assert_true(
    present(input, None, flags).report()
    is { "json": "{\"n\":9007199254740993}", .. },
  )
}

///|
test "CLI MCP strict status retains frame error precedence" {
  let strict = parse_args([
    "--mcp-guard", "--tool-schemas", "tools.json", "--strict-exit",
  ])
  let loose = parse_args(["--mcp-guard", "--tool-schemas", "tools.json"])
  assert_eq(batch_exit_status(strict, 0), 0)
  assert_eq(batch_exit_status(strict, 3), 3)
  assert_eq(batch_exit_status(strict, merge_status(3, 1)), 1)
  assert_eq(batch_exit_status(loose, 1), 0)
}
