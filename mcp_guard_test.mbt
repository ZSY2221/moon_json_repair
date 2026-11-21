///|
fn mcp_test_routes() -> @json_repair.ToolSchemaRegistry {
  @json_repair.ToolSchemaRegistry::from_json({
    "write_file": {
      "type": "object",
      "required": ["path", "bytes"],
      "properties": {
        "path": { "type": "string", "minLength": 1 },
        "bytes": { "type": "integer", "minimum": 0 },
      },
    },
    "echo": {
      "type": "object",
      "required": ["text"],
      "properties": { "text": { "type": "string" } },
    },
    "ping": { "type": "object" },
    "locked": false,
  }).unwrap()
}

///|
fn mcp_test_frame(result : @json_repair.McpGuardResult) -> Json {
  @json_repair.repair(result.frame.unwrap()).unwrap().value
}

///|
fn mcp_test_field(value : Json, key : String) -> Json {
  guard value is Object(fields) else { abort("expected an object") }
  fields[key]
}

///|
fn mcp_test_error(
  result : @json_repair.McpGuardResult,
  code : Int32,
  path : String,
) -> Json raise {
  assert_false(result.forward)
  assert_eq(result.error_code, Some(code))
  let frame = mcp_test_frame(result)
  assert_eq(mcp_test_field(frame, "jsonrpc"), Json::string("2.0"))
  let error = mcp_test_field(frame, "error")
  assert_eq(mcp_test_field(error, "code"), Json::number(code.to_double()))
  let data = mcp_test_field(error, "data")
  guard mcp_test_field(data, "issues") is Array(issues) else {
    abort("expected issue list")
  }
  assert_eq(mcp_test_field(issues[0], "path"), Json::string(path))
  assert_true(mcp_test_field(data, "retry_prompt") is String(_))
  frame
}

///|
test "MCP registry rejects a non-object schema map" {
  let error = @json_repair.ToolSchemaRegistry::from_json(Json::array([])).unwrap_err()
  assert_eq(error.path, "$schema")
  assert_eq(error.keyword, "type")
}

///|
test "MCP registry rejects an empty route name" {
  let registry = @json_repair.ToolSchemaRegistry::new()
  let error = registry.register("", Json::boolean(true)).unwrap_err()
  assert_eq(error.path, "$schema[\"\"]")
  assert_eq(error.keyword, "name")
}

///|
test "MCP registry rejects duplicate schema registration" {
  let registry = @json_repair.ToolSchemaRegistry::new()
  registry.register("echo", Json::boolean(false)).unwrap()
  let error = registry.register("echo", Json::boolean(true)).unwrap_err()
  assert_eq(error.path, "$schema.echo")
  assert_eq(error.keyword, "duplicate")
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo"}}
    ),
    registry,
  )
  ignore(mcp_test_error(result, -32602, "$.params.arguments"))
}

///|
test "MCP registry reports exact nested schema definition paths" {
  let bad = @json_repair.ToolSchemaRegistry::from_json({
    "file/write": { "properties": { "bytes": { "type": "int" } } },
  }).unwrap_err()
  assert_eq(bad.path, "$schema[\"file/write\"].properties.bytes.type")
  assert_eq(bad.keyword, "type")
}

///|
test "MCP registry rejects unsupported predicates fail closed" {
  let registry = @json_repair.ToolSchemaRegistry::new()
  let error = registry
    .register("echo", { "additionalProperties": false })
    .unwrap_err()
  assert_eq(error.path, "$schema.echo.additionalProperties")
  assert_eq(error.keyword, "additionalProperties")
}

///|
test "MCP registry clone isolates the registered schema from caller changes" {
  let rule : Json = { "type": "object", "required": ["text"] }
  let routes = @json_repair.ToolSchemaRegistry::new()
  routes.register("echo", rule).unwrap()
  guard rule is Object(fields) else { abort("expected object") }
  fields["required"] = Json::array([])
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo"}}
    ),
    routes,
  )
  ignore(mcp_test_error(result, -32602, "$.params.arguments.text"))
}

///|
test "MCP valid tool request keeps original wire formatting and decimal tokens" {
  let input =
    #|  { "jsonrpc":"2.0", "id":9007199254740993, "method":"tools/call", "params":{"name":"write_file","arguments":{"path":"notes\/a","bytes":9007199254740995}} } 
  let result = @json_repair.guard_mcp_tool_call(input, mcp_test_routes())
  assert_true(result.forward)
  assert_eq(result.frame, Some(input))
  assert_eq(result.tool, Some("write_file"))
  assert_eq(result.error_code, None)
  assert_eq(
    (
      result.audit.envelope_edits,
      result.audit.argument_edits,
      result.audit.coercions,
    ),
    (0, 0, 0),
  )
}

///|
test "MCP input repairs a truncated envelope with exact numeric ID" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"write_file","arguments":{"path":"data.txt","bytes":9007199254740995
    ),
    mcp_test_routes(),
  )
  assert_true(result.forward)
  assert_true(result.audit.envelope_edits > 0)
  assert_true(result.frame.unwrap().contains("\"id\":9007199254740993"))
  assert_true(result.frame.unwrap().contains("\"bytes\":9007199254740995"))
}

///|
test "MCP stringified arguments are repaired and decoded with separate audit" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":"req-1","method":"tools/call","params":{"name":"write_file","arguments":"{path:'notes.md',bytes:9007199254740993"}}
    ),
    mcp_test_routes(),
  )
  assert_true(result.forward)
  assert_eq(result.audit.envelope_edits, 0)
  assert_true(result.audit.argument_edits > 0)
  assert_true(
    result.frame
    .unwrap()
    .contains(
      "\"arguments\":{\"path\":\"notes.md\",\"bytes\":9007199254740993}",
    ),
  )
}

///|
test "MCP already-valid encoded argument object is still unwrapped once" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":"{\"text\":\"hello\"}"}}
    ),
    mcp_test_routes(),
  )
  assert_true(result.forward)
  assert_eq(result.audit.argument_edits, 0)
  let params = mcp_test_field(mcp_test_frame(result), "params")
  assert_eq(mcp_test_field(params, "arguments"), { "text": "hello" })
}

///|
test "MCP opt-in numeric coercion preserves exact decimals and request metadata" {
  let input =
    #|{"jsonrpc":"2.0","id":"work","method":"tools/call","trace":12,"params":{"_meta":{"progressToken":"t"},"name":"write_file","arguments":{"path":"x","bytes":"9007199254740993"}}}
  let result = @json_repair.guard_mcp_tool_call(
    input,
    mcp_test_routes(),
    coerce=true,
  )
  assert_true(result.forward)
  assert_eq(result.audit.coercions, 1)
  assert_true(result.frame.unwrap().contains("\"bytes\":9007199254740993"))
  let frame = mcp_test_frame(result)
  assert_eq(mcp_test_field(frame, "trace"), Json::number(12.0))
  assert_eq(mcp_test_field(mcp_test_field(frame, "params"), "_meta"), {
    "progressToken": "t",
  })
}

///|
test "MCP argument coercion is opt-in" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"write_file","arguments":{"path":"x","bytes":"9007199254740993"}}}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32602, "$.params.arguments.bytes"))
  assert_eq(result.audit.coercions, 0)
}

///|
test "MCP returns exact integer ID with schema retry feedback" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"write_file","arguments":{"path":"x","bytes":-1}}}
    ),
    mcp_test_routes(),
  )
  let response = mcp_test_error(result, -32602, "$.params.arguments.bytes")
  assert_eq(mcp_test_field(response, "id").stringify(), "9007199254740993")
  let data = mcp_test_field(mcp_test_field(response, "error"), "data")
  guard mcp_test_field(data, "retry_prompt") is String(prompt) else {
    abort("expected actionable feedback")
  }
  assert_true(prompt.contains("$.bytes"))
  assert_true(prompt.contains("expected number >= 0"))
}

///|
test "MCP schema rejection keeps negative zero and exponent spellings in IDs" {
  for raw_id in ["-0", "10.00e+2"] {
    let input = "{\"jsonrpc\":\"2.0\",\"id\":\{raw_id},\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}"
    let result = @json_repair.guard_mcp_tool_call(input, mcp_test_routes())
    let response = mcp_test_error(result, -32602, "$.params.arguments.text")
    assert_eq(mcp_test_field(response, "id").stringify(), raw_id)
  }
}

///|
test "MCP registered schemas isolate tool routes" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"path":"x","bytes":9}}}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32602, "$.params.arguments.text"))
  assert_eq(result.tool, Some("echo"))
}

///|
test "MCP unknown tool is denied and preserves string ID" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":"τ-3","method":"tools/call","params":{"name":"unknown","arguments":{}}}
    ),
    mcp_test_routes(),
  )
  let response = mcp_test_error(result, -32602, "$.params.name")
  assert_eq(mcp_test_field(response, "id"), Json::string("τ-3"))
  assert_eq(result.tool, Some("unknown"))
}

///|
test "MCP tool names are case-sensitive" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"Echo","arguments":{"text":"hello"}}}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32602, "$.params.name"))
}

///|
test "MCP supports tool requests without arguments when schema permits it" {
  let input =
    #|{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ping"}}
  let result = @json_repair.guard_mcp_tool_call(input, mcp_test_routes())
  assert_true(result.forward)
  assert_eq(result.frame, Some(input))
}

///|
test "MCP explicit null arguments are rejected" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ping","arguments":null}}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32602, "$.params.arguments"))
}

///|
test "MCP object arguments are still required under an unconstrained schema" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ping","arguments":[1,2]}}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32602, "$.params.arguments"))
}

///|
test "MCP denies malformed embedded arguments without losing correlation" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":"req-3","method":"tools/call","params":{"name":"echo","arguments":"{\"text\":1,\"text\":2}"}}
    ),
    mcp_test_routes(),
  )
  let response = mcp_test_error(result, -32602, "$.params.arguments")
  assert_eq(mcp_test_field(response, "id"), Json::string("req-3"))
  assert_true(result.frame.unwrap().contains("\"keyword\":\"duplicate_key\""))
}

///|
test "MCP denies missing invocation params" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"method":"tools/call"}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32602, "$.params"))
}

///|
test "MCP requires an explicit nonempty tool name before routing" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":""}}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32602, "$.params.name"))
}

///|
test "MCP rejects a no-ID tools/call without emitting an illegal reply" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","method":"tools/call","params":{"name":"ping","arguments":{}}}
    ),
    mcp_test_routes(),
  )
  assert_false(result.forward)
  assert_eq(result.error_code, Some(-32602))
  assert_eq(result.frame, None)
}

///|
test "MCP forwards initialization and list requests byte for byte" {
  for
    input in [
      "  {\"jsonrpc\":\"2.0\", \"id\":1, \"method\":\"initialize\", \"params\":{\"protocolVersion\":\"2025-11-25\"}} ",
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
    ] {
    let result = @json_repair.guard_mcp_tool_call(input, mcp_test_routes())
    assert_true(result.forward)
    assert_eq(result.frame, Some(input))
    assert_eq(result.tool, None)
  }
}

///|
test "MCP forwards non-tool notifications without synthesizing an ID" {
  let input =
    #|{"jsonrpc":"2.0","method":"notifications/initialized"}
  let result = @json_repair.guard_mcp_tool_call(input, mcp_test_routes())
  assert_true(result.forward)
  assert_eq(result.frame, Some(input))
  assert_eq(result.error_code, None)
}

///|
test "MCP drops an invalid idless non-tool notification without replying" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","method":"notifications/progress","params":false}
    ),
    mcp_test_routes(),
  )
  assert_false(result.forward)
  assert_eq(result.frame, None)
  assert_eq(result.error_code, Some(-32602))
}

///|
test "MCP repairs a truncated non-tool request without applying a tool schema" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":12,"method":"tools/list"
    ),
    mcp_test_routes(),
  )
  assert_true(result.forward)
  assert_true(result.audit.envelope_edits > 0)
  assert_eq(result.tool, None)
  assert_eq(
    result.frame,
    Some("{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/list\"}"),
  )
}

///|
test "MCP compacts physically multiline input to a one-line wire frame" {
  let result = @json_repair.guard_mcp_tool_call(
    "{\r\n \"jsonrpc\":\"2.0\",\n \"method\":\"notifications/initialized\"\n}",
    mcp_test_routes(),
  )
  assert_true(result.forward)
  assert_eq(result.audit.envelope_edits, 0)
  assert_eq(
    result.frame,
    Some("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"),
  )
}

///|
test "MCP forwards a result response without routing it as a request" {
  let source =
    #|{"jsonrpc":"2.0","id":9007199254740993,"result":{"size":9007199254740995}}
  let result = @json_repair.guard_mcp_tool_call(source, mcp_test_routes())
  assert_true(result.forward)
  assert_eq(result.frame, Some(source))
  assert_eq(result.tool, None)
}

///|
test "MCP forwards malformed-request error responses without a known ID" {
  for
    source in [
      "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}",
      "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}",
    ] {
    let result = @json_repair.guard_mcp_tool_call(source, mcp_test_routes())
    assert_true(result.forward)
    assert_eq(result.frame, Some(source))
  }
}

///|
test "MCP does not forward a response containing both result and error" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-32602,"message":"Invalid params"}}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32600, "$.method"))
}

///|
test "MCP result responses must include a matching-shaped ID" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","result":{}}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32600, "$.method"))
}

///|
test "MCP response error codes must be integers" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"error":{"code":-32602.5,"message":"Invalid params"}}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32600, "$.method"))
}

///|
test "MCP rejects response error values that are not objects" {
  let input =
    #|{"jsonrpc":"2.0","id":1,"error":"failed"}
  let result = @json_repair.guard_mcp_tool_call(input, mcp_test_routes())
  ignore(mcp_test_error(result, -32600, "$.method"))
}

///|
test "MCP rejects error objects missing required fields" {
  for
    source in [
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"message\":\"failed\"}}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602}}",
    ] {
    let result = @json_repair.guard_mcp_tool_call(source, mcp_test_routes())
    ignore(mcp_test_error(result, -32600, "$.method"))
  }
}

///|
test "MCP rejects batch arrays instead of routing unvalidated tool calls" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ping"}}]
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32600, "$"))
}

///|
test "MCP malformed frame uses a parse error with a null ID" {
  let result = @json_repair.guard_mcp_tool_call(
    "unparseable frame",
    mcp_test_routes(),
  )
  let response = mcp_test_error(result, -32700, "$")
  assert_eq(mcp_test_field(response, "id"), Json::null())
}

///|
test "MCP rejects duplicate procedure keys before routing" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":9,"method":"tools/list","method":"tools/call","params":{"name":"ping"}}
    ),
    mcp_test_routes(),
  )
  let response = mcp_test_error(result, -32700, "$")
  assert_eq(mcp_test_field(response, "id"), Json::null())
  assert_true(result.frame.unwrap().contains("\"keyword\":\"duplicate_key\""))
}

///|
test "MCP requires an exact JSON-RPC 2.0 version marker" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"1.0","id":7,"method":"tools/list"}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32600, "$.jsonrpc"))
}

///|
test "MCP rejects null and fractional request identifiers" {
  for id in ["null", "1.5", "[1]"] {
    let result = @json_repair.guard_mcp_tool_call(
      "{\"jsonrpc\":\"2.0\",\"id\":\{id},\"method\":\"tools/list\"}",
      mcp_test_routes(),
    )
    let response = mcp_test_error(result, -32600, "$.id")
    assert_eq(mcp_test_field(response, "id"), Json::null())
  }
}

///|
test "MCP rejects positional arrays on non-tool methods" {
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":9,"method":"initialize","params":[]}
    ),
    mcp_test_routes(),
  )
  ignore(mcp_test_error(result, -32602, "$.params"))
}

///|
test "MCP think filtering is opt-in and counted as envelope repair" {
  let policy = @json_repair.RepairOptions::default().with_ignore_think_blocks(
    true,
  )
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|<think>{"decoy":1}</think>{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ping"}}
    ),
    mcp_test_routes(),
    policy~,
  )
  assert_true(result.forward)
  assert_true(result.audit.envelope_edits > 0)
  assert_false(result.frame.unwrap().contains("decoy"))
}

///|
test "MCP opted-in JSON5 repair retains exact converted argument integers" {
  let policy : @json_repair.RepairPolicy = {
    options: { ..@json_repair.RepairOptions::default(), json5: true, },
    ignore_think_blocks: false,
  }
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{jsonrpc:'2.0',id:3,method:'tools/call',params:{name:'write_file',arguments:{path:'x',bytes:0x20000000000001}}}
    ),
    mcp_test_routes(),
    policy~,
  )
  assert_true(result.forward)
  assert_true(result.frame.unwrap().contains("\"bytes\":9007199254740993"))
}

///|
test "MCP uses caller framing budgets on outer documents" {
  let options = @json_repair.RepairOptions::default()
  let policy : @json_repair.RepairPolicy = {
    options: { ..options, limits: { ..options.limits, max_input: 16, }, },
    ignore_think_blocks: false,
  }
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":9,"method":"tools/list"}
    ),
    mcp_test_routes(),
    policy~,
  )
  ignore(mcp_test_error(result, -32700, "$"))
  assert_true(result.frame.unwrap().contains("\"keyword\":\"input_limit\""))
}

///|
test "MCP limits validation feedback without dropping the first exact paths" {
  let routes = @json_repair.ToolSchemaRegistry::from_json({
    "fill": {
      "required": [
        "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "b0", "b1", "b2",
        "b3", "b4", "b5", "b6", "b7",
      ],
    },
  }).unwrap()
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fill"}}
    ),
    routes,
  )
  let response = mcp_test_error(result, -32602, "$.params.arguments.a0")
  let data = mcp_test_field(mcp_test_field(response, "error"), "data")
  assert_eq(mcp_test_field(data, "remaining"), Json::number(2.0))
  guard mcp_test_field(data, "issues") is Array(issues) else {
    abort("expected bounded issues")
  }
  assert_eq(issues.length(), 16)
}

///|
test "MCP escaped validation keys keep full path precision" {
  let routes = @json_repair.ToolSchemaRegistry::from_json({
    "fill": { "required": ["slash/~ key"] },
  }).unwrap()
  let result = @json_repair.guard_mcp_tool_call(
    (
      #|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fill"}}
    ),
    routes,
  )
  ignore(mcp_test_error(result, -32602, "$.params.arguments[\"slash/~ key\"]"))
}
