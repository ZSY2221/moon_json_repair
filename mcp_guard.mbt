///|
/// Case-sensitive, fail-closed routing from MCP tool names to input schemas.
/// Registration validates the same schema subset as [validate] and copies each
/// definition, so changing the input JSON later does not change the guard.
pub struct ToolSchemaRegistry {
  priv schemas : Map[String, Json]
}

///|
/// Start with an empty registry. Tools are denied until explicitly registered.
pub fn ToolSchemaRegistry::new() -> ToolSchemaRegistry {
  { schemas: Map([]), }
}

///|
/// Register one nonempty tool name and a valid input schema. A duplicate name
/// returns an error and keeps the existing route.
pub fn ToolSchemaRegistry::register(
  self : ToolSchemaRegistry,
  name : String,
  schema : JsonValue,
) -> Result[Unit, ValidationError] {
  let path = schema_key_path("$schema", name)
  if name.is_empty() {
    return Err({
      path,
      keyword: "name",
      message: "expected a nonempty tool name",
    })
  }
  if self.schemas.contains(name) {
    return Err({
      path,
      keyword: "duplicate",
      message: "tool already registered",
    })
  }
  let errors = []
  check_schema(schema, path, 0, errors)
  if errors.get(0) is Some(error) {
    return Err(error)
  }
  self.schemas[name] = clone_patch_value(schema)
  Ok(())
}

///|
/// Build a registry from a JSON object keyed by tool name. For example,
/// {"write_file":{"type":"object","required":["path"]}} registers one tool.
/// An invalid definition rejects the entire map.
pub fn ToolSchemaRegistry::from_json(
  schemas : JsonValue,
) -> Result[ToolSchemaRegistry, ValidationError] {
  guard schemas is Object(fields) else {
    return Err({
      path: "$schema",
      keyword: "type",
      message: "expected an object mapping tool names to input schemas",
    })
  }
  let registry = ToolSchemaRegistry::new()
  let names = fields.keys().collect()
  names.sort_by(String::lexical_compare)
  for name in names {
    if registry.register(name, fields[name]) is Err(error) {
      return Err(error)
    }
  }
  Ok(registry)
}

///|
/// Counts of edits to the incoming frame, repairs inside stringified
/// arguments, and optional schema-directed coercions, respectively.
#derive(Eq, Debug, ToJson)
pub struct McpGuardAudit {
  envelope_edits : Int32
  argument_edits : Int32
  coercions : Int32
}

///|
/// Routing decision for one JSON-RPC frame. With [forward] true, send [frame]
/// to the server. Otherwise, route any [frame] back to the requesting client.
/// A rejected notification has an [error_code] but no wire reply.
/// [tool] is set when the frame identifies a tool by name.
#derive(Eq, Debug, ToJson)
pub struct McpGuardResult {
  forward : Bool
  frame : String?
  tool : String?
  audit : McpGuardAudit
  error_code : Int32?
}

///|
let mcp_argument_path : String = "$.params.arguments"

///|
fn mcp_error_frame(
  code : Int32,
  message : String,
  id : Json?,
  tool : String?,
  issues : Array[ValidationError],
  retry : String,
  audit : McpGuardAudit,
) -> McpGuardResult {
  let frame = id.map(id => {
    let count = issues.length().min(retry_issue_limit)
    let visible = Array::makei(count, index => @json.to_json(issues[index]))
    let details : Map[String, Json] = {
      "issues": Json::array(visible),
      "retry_prompt": Json::string(retry),
    }
    if count < issues.length() {
      details["remaining"] = Json::number((issues.length() - count).to_double())
    }
    let error : Json = {
      "code": Json::number(code.to_double()),
      "message": Json::string(message),
      "data": Json::object(details),
    }
    let response : Json = { "jsonrpc": "2.0", "id": id, "error": error }
    response.stringify()
  })
  { forward: false, frame, tool, audit, error_code: Some(code), }
}

///|
fn mcp_structure_error(
  code : Int32,
  id : Json?,
  path : String,
  keyword : String,
  detail : String,
  audit : McpGuardAudit,
  tool~ : String? = None,
) -> McpGuardResult {
  let message = match code {
    -32700 => "Parse error"
    -32600 => "Invalid Request"
    _ => "Invalid params"
  }
  let issue : ValidationError = { path, keyword, message: detail, }
  mcp_error_frame(
    code,
    message,
    id,
    tool,
    [issue],
    "Fix \{path}: \{detail}",
    audit,
  )
}

///|
fn is_mcp_id(id : Json) -> Bool {
  id is String(_) || schema_matches_type(id, "integer")
}

///|
fn is_mcp_error(error : Json) -> Bool {
  guard error is Object(fields) else { return false }
  guard fields.get("message") is Some(String(_)) &&
    fields.get("code") is Some(code) else {
    return false
  }
  schema_matches_type(code, "integer")
}

///|
fn is_mcp_response(fields : Map[String, Json], id : Json?) -> Bool {
  match (fields.get("result"), fields.get("error")) {
    (Some(Object(_)), None) => id is Some(reply_id) && is_mcp_id(reply_id)
    (None, Some(error)) =>
      (
        id is (None | Some(Null)) ||
        (id is Some(reply_id) && is_mcp_id(reply_id))
      ) &&
      is_mcp_error(error)
    _ => false
  }
}

///|
fn mcp_wire_text(source : String, report : RepairReport) -> String {
  // Keep valid one-line input untouched, including numeric and string lexemes.
  // Compact physical line breaks to preserve stdio's one-message-per-line rule.
  if report.edits.is_empty() && !source.contains("\n") && !source.contains("\r") {
    source
  } else {
    report.json
  }
}

///|
fn mcp_forward(
  frame : String,
  audit : McpGuardAudit,
  tool~ : String? = None,
) -> McpGuardResult {
  { forward: true, frame: Some(frame), tool, audit, error_code: None, }
}

///|
fn guard_mcp_arguments(
  raw : Json,
  id : Json?,
  tool : String,
  policy : RepairPolicy,
  audit : McpGuardAudit,
) -> Result[(Json, Bool, McpGuardAudit), McpGuardResult] {
  let (value, unwrapped, audit) = match raw {
    String(embedded) =>
      match repair_with_policy(embedded, policy) {
        Ok(report) =>
          (
            report.value,
            true,
            { ..audit, argument_edits: report.edits.length(), },
          )
        Err(error) =>
          return Err(
            mcp_structure_error(
              -32602,
              id,
              mcp_argument_path,
              error.kind.code(),
              "expected an encoded JSON object",
              audit,
              tool=Some(tool),
            ),
          )
      }
    _ => (raw, false, audit)
  }
  guard value is Object(_) else {
    return Err(
      mcp_structure_error(
        -32602,
        id,
        mcp_argument_path,
        "type",
        "expected an arguments object",
        audit,
        tool=Some(tool),
      ),
    )
  }
  Ok((value, unwrapped, audit))
}

///|
fn guard_mcp_invocation(
  fields : Map[String, Json],
  id : Json?,
  registry : ToolSchemaRegistry,
  policy : RepairPolicy,
  coerce : Bool,
  wire : String,
  audit : McpGuardAudit,
) -> McpGuardResult {
  guard id is Some(_) else {
    return mcp_structure_error(
      -32602,
      None,
      "$.id",
      "required",
      "tools/call requires an id",
      audit,
    )
  }
  guard fields.get("params") is Some(Object(parameters)) else {
    return mcp_structure_error(
      -32602, id, "$.params", "type", "expected a params object", audit,
    )
  }
  guard parameters.get("name") is Some(String(tool)) && !tool.is_empty() else {
    return mcp_structure_error(
      -32602, id, "$.params.name", "type", "expected a nonempty tool name", audit,
    )
  }
  guard registry.schemas.get(tool) is Some(schema) else {
    return mcp_structure_error(
      -32602,
      id,
      "$.params.name",
      "registered",
      "expected a registered tool name",
      audit,
      tool=Some(tool),
    )
  }
  let raw = parameters.get("arguments").unwrap_or(Json::empty_object())
  let (value, unwrapped, audit) = match
    guard_mcp_arguments(raw, id, tool, policy, audit) {
    Ok(decoded) => decoded
    Err(result) => return result
  }
  let (value, errors, audit) = if coerce {
    let report = coerce_with_schema(value, schema)
    (
      report.value,
      report.errors,
      { ..audit, coercions: report.edits.length(), },
    )
  } else {
    (value, validate(value, schema), audit)
  }
  if !errors.is_empty() {
    let issues = errors.map(error => {
      let suffix = error.path[:].exact_view(start=1)
      { ..error, path: mcp_argument_path + suffix.to_owned(), }
    })
    return mcp_error_frame(
      -32602,
      "Invalid params",
      id,
      Some(tool),
      issues,
      format_retry_prompt(value, schema),
      audit,
    )
  }
  if !unwrapped && audit.coercions == 0 {
    return mcp_forward(wire, audit, tool=Some(tool))
  }
  let next_parameters = parameters.copy()
  next_parameters["arguments"] = value
  let next_fields = fields.copy()
  next_fields["params"] = Json::object(next_parameters)
  mcp_forward(Json::object(next_fields).stringify(), audit, tool=Some(tool))
}

///|
/// Repair and route a single inbound MCP JSON-RPC 2.0 frame. Known tools must
/// pass their registered input schema. Stringified arguments are repaired and
/// unwrapped once. Enable [coerce] to apply explicit schema-directed type
/// conversions. Successful unchanged one-line frames retain their wire bytes.
///
/// Irreparable JSON returns -32700, invalid envelopes return -32600, and
/// rejected tool parameters return -32602. Notifications cannot receive
/// replies. The guard never spawns a transport or authorizes tool execution.
pub fn guard_mcp_tool_call(
  source : String,
  registry : ToolSchemaRegistry,
  policy~ : RepairPolicy = RepairPolicy::default(),
  coerce~ : Bool = false,
) -> McpGuardResult {
  let audit = { envelope_edits: 0, argument_edits: 0, coercions: 0, }
  let report = match repair_with_policy(source, policy) {
    Ok(report) => report
    Err(error) =>
      return mcp_structure_error(
        -32700,
        Some(Json::null()),
        "$",
        error.kind.code(),
        "expected one repairable JSON-RPC object",
        audit,
      )
  }
  let audit = { ..audit, envelope_edits: report.edits.length(), }
  let unknown = Some(Json::null())
  guard report.value is Object(fields) else {
    return mcp_structure_error(
      -32600, unknown, "$", "type", "expected one JSON-RPC object", audit,
    )
  }
  guard fields.get("jsonrpc") is Some(String("2.0")) else {
    return mcp_structure_error(
      -32600, unknown, "$.jsonrpc", "version", "expected JSON-RPC 2.0", audit,
    )
  }
  let wire = mcp_wire_text(source, report)
  let id = fields.get("id")
  let procedure = fields.get("method")
  // Valid replies can travel through this filter in the reverse direction.
  if procedure is None && is_mcp_response(fields, id) {
    return mcp_forward(wire, audit)
  }
  guard procedure is Some(String(name)) &&
    !name.is_empty() &&
    !fields.contains("result") &&
    !fields.contains("error") else {
    return mcp_structure_error(
      -32600, unknown, "$.method", "type", "expected a JSON-RPC method", audit,
    )
  }
  if id is Some(request_id) && !is_mcp_id(request_id) {
    return mcp_structure_error(
      -32600, unknown, "$.id", "type", "expected a string or integer id", audit,
    )
  }
  if name == "tools/call" {
    return guard_mcp_invocation(
      fields, id, registry, policy, coerce, wire, audit,
    )
  }
  if fields.get("params") is Some(parameters) && !(parameters is Object(_)) {
    return mcp_structure_error(
      -32602, id, "$.params", "type", "expected a params object", audit,
    )
  }
  mcp_forward(wire, audit)
}
