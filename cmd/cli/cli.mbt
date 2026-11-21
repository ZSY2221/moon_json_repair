///|
/// Parsed options shared by single-document, NDJSON, SSE and MCP modes.
pub struct Options {
  input : String?
  schema : String?
  ndjson : Bool
  sse : Bool
  mcp_guard : Bool
  tool_schemas : String?
  emit_patches : Bool
  extract_all : Bool
  ignore_think : Bool
  json5 : Bool
  coerce : Bool
  retry_prompt : Bool
  strict_exit : Bool
}

///|
/// Fatal CLI diagnostic with the process exit status.
pub(all) suberror CliFailure {
  CliFailure(Json, Int32)
}

///|
fn error_json(kind : String, message : String) -> Json {
  { "kind": Json::string(kind), "message": Json::string(message) }
}

///|
/// Raise a structured startup or transport failure.
pub fn[T] fail_cli(
  kind : String,
  message : String,
  status~ : Int32 = 1,
) -> T raise CliFailure {
  raise CliFailure(error_json(kind, message), status)
}

///|
/// Parse switches, check mode-specific prerequisites, and resolve stdin.
pub fn parse_args(args : ArrayView[String]) -> Options raise CliFailure {
  let mut options : Options = {
    input: None,
    schema: None,
    ndjson: false,
    sse: false,
    mcp_guard: false,
    tool_schemas: None,
    emit_patches: false,
    extract_all: false,
    ignore_think: false,
    json5: false,
    coerce: false,
    retry_prompt: false,
    strict_exit: false,
  }
  let mut positional_only = false
  for remaining = args {
    match remaining {
      [] => break
      ["--schema", path, .. rest] if !positional_only => {
        if options.schema is Some(_) {
          fail_cli("usage", "--schema may only be supplied once", status=2)
        }
        options = { ..options, schema: Some(path), }
        continue rest
      }
      ["--schema"] if !positional_only =>
        fail_cli("usage", "--schema requires a file path", status=2)
      ["--tool-schemas", path, .. rest] if !positional_only => {
        if options.tool_schemas is Some(_) {
          fail_cli(
            "usage",
            "--tool-schemas may only be supplied once",
            status=2,
          )
        }
        options = { ..options, tool_schemas: Some(path), }
        continue rest
      }
      ["--tool-schemas"] if !positional_only =>
        fail_cli("usage", "--tool-schemas requires a file path", status=2)
      ["--", .. rest] if !positional_only => {
        positional_only = true
        continue rest
      }
      [argument, .. rest] => {
        options = match argument {
          "--ndjson" if !positional_only => { ..options, ndjson: true, }
          "--sse" if !positional_only => { ..options, sse: true, }
          "--mcp-guard" if !positional_only => { ..options, mcp_guard: true, }
          "--emit-patches" if !positional_only =>
            { ..options, emit_patches: true, }
          "--extract-all" if !positional_only =>
            { ..options, extract_all: true, }
          "--ignore-think" if !positional_only =>
            { ..options, ignore_think: true, }
          "--json5" if !positional_only => { ..options, json5: true, }
          "--coerce" if !positional_only => { ..options, coerce: true, }
          "--retry-prompt" if !positional_only =>
            { ..options, retry_prompt: true, }
          "--strict-exit" if !positional_only =>
            { ..options, strict_exit: true, }
          _ => {
            if !positional_only && argument != "-" && argument.has_prefix("-") {
              fail_cli("usage", "unknown option \{argument}", status=2)
            }
            if options.input is Some(_) {
              fail_cli("usage", "expected at most one input path", status=2)
            }
            { ..options, input: Some(argument), }
          }
        }
        continue rest
      }
    }
  }
  if options.mcp_guard {
    if options.tool_schemas is None {
      fail_cli("usage", "--mcp-guard requires --tool-schemas", status=2)
    }
    if options.ndjson ||
      options.sse ||
      options.extract_all ||
      options.schema is Some(_) ||
      options.retry_prompt {
      fail_cli(
        "usage",
        "--mcp-guard conflicts with --ndjson, --sse, --extract-all, --schema and --retry-prompt",
        status=2,
      )
    }
  } else if options.tool_schemas is Some(_) {
    fail_cli("usage", "--tool-schemas requires --mcp-guard", status=2)
  } else if options.schema is None && (options.coerce || options.retry_prompt) {
    fail_cli("usage", "--coerce and --retry-prompt require --schema", status=2)
  }
  if options.sse && (options.ndjson || options.extract_all) {
    fail_cli(
      "usage",
      "--sse conflicts with --ndjson and --extract-all",
      status=2,
    )
  }
  if options.emit_patches && !options.sse {
    fail_cli("usage", "--emit-patches requires --sse", status=2)
  }
  if options.input == Some("-") {
    { ..options, input: None, }
  } else {
    options
  }
}

///|
/// Read a strict schema document, preserving exact numbers and unique keys.
pub fn parse_schema(text : String) -> Json raise CliFailure {
  @json.parse(
    text[:],
    max_nesting_depth=514,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error =>
      fail_cli("schema_parse", "could not parse schema: \{error.to_string()}")
  }
}

///|
/// Repaired input before schema validation and CLI report generation.
pub enum PreparedInput {
  Single(@repair.RepairReport)
  Multiple(Array[@repair.ExtractedBlock])
}

///|
fn cli_policy(options : Options) -> @repair.RepairPolicy {
  let defaults = @repair.RepairOptions::default()
  {
    options: { ..defaults, json5: options.json5, },
    ignore_think_blocks: options.ignore_think,
  }
}

///|
/// Repair one block or extract separate blocks according to the input mode.
pub fn prepare_input(
  source : String,
  options : Options,
) -> Result[PreparedInput, Json] {
  let policy = cli_policy(options)
  if options.extract_all {
    match @repair.extract_all_with_policy(source, policy) {
      Ok(blocks) if blocks.is_empty() =>
        Err(error_json("no_blocks", "input did not contain a repairable block"))
      Ok(blocks) => Ok(Multiple(blocks))
      Err(error) => Err(@json.to_json(error))
    }
  } else {
    match @repair.repair_with_policy(source, policy) {
      Ok(report) => Ok(Single(report))
      Err(error) => Err(@json.to_json(error))
    }
  }
}

///|
/// Structured CLI result and exit status before transport framing.
pub struct Outcome {
  fields : Map[String, Json]
  status : Int32
}

///|
/// Return the existing CLI JSON report.
pub fn Outcome::report(self : Outcome) -> Json {
  Json::object(self.fields)
}

///|
/// Attach the original physical line number to an NDJSON report.
pub fn Outcome::for_line(self : Outcome, line : Int64) -> Json {
  let fields : Map[String, Json] = {
    "line": Json::number(line.to_double(), repr=line.to_string()),
    "ok": Json::boolean(self.status == 0),
    "status": @json.to_json(self.status),
  }
  for key, value in self.fields {
    fields[key] = value
  }
  Json::object(fields)
}

///|
fn present_report(
  report : @repair.RepairReport,
  schema : Json?,
  options : Options,
) -> Outcome {
  let (text, value, coercions, errors) = match schema {
    None => (report.json, report.value, Json::array([]), [])
    Some(schema) if options.coerce => {
      let coerced = @repair.coerce_with_schema(report.value, schema)
      (
        coerced.json,
        coerced.value,
        @json.to_json(coerced.edits),
        coerced.errors,
      )
    }
    Some(schema) =>
      (
        report.json,
        report.value,
        Json::array([]),
        @repair.validate(report.value, schema),
      )
  }
  let schema_report : Json = if schema is Some(_) {
    {
      "valid": Json::boolean(errors.is_empty()),
      "errors": @json.to_json(errors),
    }
  } else {
    Json::null()
  }
  let fields : Map[String, Json] = {
    "json": Json::string(text),
    "value": value,
    "edits": @json.to_json(report.edits),
    "schema": schema_report,
  }
  if options.coerce {
    fields["coercions"] = coercions
  }
  if options.retry_prompt && schema is Some(schema) {
    fields["retry_prompt"] = Json::string(
      if errors.is_empty() {
        ""
      } else {
        @repair.format_retry_prompt(value, schema)
      },
    )
  }
  { fields, status: if errors.is_empty() { 0 } else { 3 }, }
}

///|
/// Validate repaired values, optionally coerce them, and build the CLI report.
pub fn present(
  input : PreparedInput,
  schema : Json?,
  options : Options,
) -> Outcome {
  match input {
    Single(report) => present_report(report, schema, options)
    Multiple(blocks) => {
      let mut status = 0
      let reports = blocks.map(block => {
        let outcome = present_report(block.report, schema, options)
        status = merge_status(status, outcome.status)
        let fields = outcome.fields
        fields["start"] = @json.to_json(block.start)
        fields["end"] = @json.to_json(block.end)
        fields["confidence"] = @json.to_json(block.confidence)
        outcome.report()
      })
      { fields: { "blocks": Json::array(reports) }, status, }
    }
  }
}

///|
/// Combine stream statuses, giving input failures precedence over validation.
pub fn merge_status(previous : Int32, next : Int32) -> Int32 {
  if previous == 1 || next == 1 {
    1
  } else if previous == 3 || next == 3 {
    3
  } else {
    0
  }
}

///|
/// Ignore accumulated line errors unless strict exit behavior was requested.
pub fn batch_exit_status(options : Options, status : Int32) -> Int32 {
  if options.strict_exit {
    status
  } else {
    0
  }
}

///|
/// Result of reading one physical input line with its one-based position.
pub struct BatchLine {
  line : Int64
  input : Result[String, Json]
}

///|
/// Repair and validate an NDJSON record while preserving transport failures.
pub fn process_line(
  line : BatchLine,
  schema : Json?,
  options : Options,
) -> Outcome {
  match line.input {
    Err(error) => { fields: { "error": error }, status: 1, }
    Ok(source) =>
      match prepare_input(source, options) {
        Err(error) => { fields: { "error": error }, status: 1, }
        Ok(input) => present(input, schema, options)
      }
  }
}

///|
/// Reads one physical line at a time, retaining at most one bounded byte
/// buffer. Oversized line tails are discarded through the next LF.
pub struct BatchLines {
  priv buffer : @buffer.Buffer
  priv max_chars : Int32
  priv max_bytes : Int32
  priv mut line : Int64
  priv mut overflow : Bool
}

///|
/// Start a bounded physical-line decoder with a UTF-16 text budget.
pub fn BatchLines::new(max_chars~ : Int32) -> BatchLines {
  let max_chars = max_chars.clamp(
    min=0,
    max=@repair.RepairLimits::default().max_input,
  )
  {
    buffer: @buffer.Buffer(),
    max_chars,
    max_bytes: max_chars * 3 + 3,
    line: 1L,
    overflow: false,
  }
}

///|
fn line_limit_error() -> Json {
  error_json("input_limit", "input line exceeds the supported input size")
}

///|
fn BatchLines::emit(self : BatchLines) -> BatchLine {
  let line = self.line
  self.line += 1L
  let input = if self.overflow {
    Err(line_limit_error())
  } else {
    let bytes = self.buffer.to_bytes()
    let len = bytes.length()
    let end = if len > 0 && bytes[len - 1] == b'\r' { len - 1 } else { len }
    try @utf8.decode(bytes[:end], ignore_bom=false) catch {
      _ => Err(error_json("invalid_utf8", "input line must be valid UTF-8"))
    } noraise {
      text if text.length() > self.max_chars => Err(line_limit_error())
      text => Ok(text)
    }
  }
  self.buffer.reset()
  self.overflow = false
  { line, input, }
}

///|
/// Consume bytes up to the next LF or the end of the chunk.
pub fn BatchLines::next(
  self : BatchLines,
  chunk : BytesView,
  offset : Int32,
) -> (Int32, BatchLine?) {
  let tail = chunk[offset:]
  let lf = tail.find(b"\n"[:])
  let size = lf.unwrap_or(tail.length())
  if !self.overflow {
    if size > self.max_bytes - self.buffer.length() {
      self.overflow = true
      self.buffer.reset()
    } else {
      self.buffer.write_bytes(tail[:size])
    }
  }
  match lf {
    Some(_) => (offset + size + 1, Some(self.emit()))
    None => (chunk.length(), None)
  }
}

///|
/// Emit a buffered final line at end of input.
pub fn BatchLines::finish(self : BatchLines) -> BatchLine? {
  if self.buffer.is_empty() && !self.overflow {
    None
  } else {
    Some(self.emit())
  }
}
