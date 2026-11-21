///|
/// Read the strict JSON object mapping allowed MCP tool names to schemas.
pub fn parse_tool_schemas(
  text : String,
) -> @repair.ToolSchemaRegistry raise CliFailure {
  match @repair.ToolSchemaRegistry::from_json(parse_schema(text)) {
    Ok(registry) => registry
    Err(error) => fail_cli("tool_schemas", "\{error.path}: \{error.message}")
  }
}

///|
/// Produce one raw JSON-RPC line and status, or suppress a refused
/// notification. Reuse the bounded UTF-8 physical-line decoder.
pub fn process_mcp_line(
  line : BatchLine,
  registry : @repair.ToolSchemaRegistry,
  options : Options,
) -> (String?, Int32) {
  match line.input {
    Err(error) => {
      let response : Json = {
        "jsonrpc": "2.0",
        "id": Json::null(),
        "error": {
          "code": @json.to_json(-32700),
          "message": "Parse error",
          "data": error,
        },
      }
      (Some(response.stringify()), 1)
    }
    Ok(source) => {
      let checked = @repair.guard_mcp_tool_call(
        source,
        registry,
        policy=cli_policy(options),
        coerce=options.coerce,
      )
      let status = if checked.forward {
        0
      } else if checked.error_code == Some(-32602) {
        3
      } else {
        1
      }
      (checked.frame, status)
    }
  }
}
