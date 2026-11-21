///|
let usage : String =
  #|Usage: moon run --target native cmd/main -- [OPTIONS] [INPUT|-]
  #|
  #|Read JSON or a stream from INPUT or from standard input.
  #|  --schema FILE    Check against a strict JSON schema document.
  #|  --ndjson         Process each physical line and continue after line errors.
  #|  --sse            Parse provider SSE tool-call arguments, emitting JSON lines.
  #|  --emit-patches   Emit RFC 6902 progress and pointer state with --sse.
  #|  --mcp-guard      Filter one MCP JSON-RPC frame per physical line.
  #|  --tool-schemas FILE  Read the tool-to-schema JSON registry for --mcp-guard.
  #|  --extract-all    Return all repairable JSON blocks.
  #|  --ignore-think   Skip reasoning blocks before repairing JSON.
  #|  --json5          Allow the supported JSON5-style repair syntax.
  #|  --coerce         Coerce schema-typed numeric and Boolean strings.
  #|  --retry-prompt   Include a repair prompt for schema errors.
  #|  --diagnostic-format json|pretty|ansi
  #|                   Print optional source diagnostics for JSON/NDJSON input.
  #|  --strict-exit    Return 1 for input errors or 3 for schema/parameter errors.
  #|
  #|--coerce requires --schema or --mcp-guard. --retry-prompt requires --schema.
  #|MCP guard output contains forwarded frames and local JSON-RPC errors.
  #|Route these separately when integrating with a bidirectional MCP server.

///|
async fn read_bounded(
  reader : &@io.BinaryReader,
  label : String,
  max_chars : Int32,
  preserve_bom : Bool,
) -> String {
  // An encoded UTF-16 code unit requires at most three UTF-8 bytes.
  let max_bytes = max_chars * 3 + 3
  let content = @buffer.Buffer()
  while reader.read() is Some(chunk) {
    if chunk.length() > max_bytes - content.length() {
      @cli.fail_cli("input_limit", "\{label} exceeds the supported input size")
    }
    content.write_bytes(chunk[:])
  }
  let text = @utf8.decode(content.to_bytes()[:], ignore_bom=!preserve_bom) catch {
    _ => @cli.fail_cli("invalid_utf8", "\{label} must be valid UTF-8")
  }
  if text.length() > max_chars {
    @cli.fail_cli("input_limit", "\{label} exceeds the supported input size")
  }
  text
}

///|
async fn read_path(
  path : String?,
  label : String,
  max_chars : Int32,
  preserve_bom : Bool,
) -> String {
  try {
    match path {
      None => read_bounded(@stdio.stdin, label, max_chars, preserve_bom)
      Some(path) => {
        let file = @fs.open(path[:], mode=ReadOnly)
        defer file.close()
        read_bounded(file, label, max_chars, preserve_bom)
      }
    }
  } catch {
    @cli.CliFailure(_, _) as error => raise error
    error =>
      @cli.fail_cli("io", "could not read \{label}: \{error.to_string()}")
  }
}

///|
priv struct LoadedSchema {
  value : Json?
  source : String?
}

///|
async fn read_schema(path : String?, max_chars : Int32) -> LoadedSchema {
  match path {
    None => { value: None, source: None, }
    Some(path) => {
      let source = read_path(Some(path), "schema", max_chars, false)
      { value: Some(@cli.parse_schema(source)), source: Some(source), }
    }
  }
}

///|
async fn write_source_diagnostics(report : Json) -> Unit {
  if report is { "error": { "diagnostic": String(text), .. }, .. } {
    @stdio.stderr.text.write(text)
  }
  if report is { "repair_diagnostic": String(text), .. } {
    @stdio.stderr.text.write(text)
  }
  if report is { "schema_diagnostic": String(text), .. } {
    @stdio.stderr.text.write(text)
  }
  if report is { "blocks": Array(blocks), .. } {
    for block in blocks {
      write_source_diagnostics(block)
    }
  }
}

///|
async fn write_batch_line(
  record : @cli.BatchLine,
  schema : LoadedSchema,
  options : @cli.Options,
  registry : @repair.ToolSchemaRegistry?,
  format : @cli.DiagnosticFormat,
) -> Int32 {
  if registry is Some(registry) {
    let (frame, status) = @cli.process_mcp_line(record, registry, options)
    if frame is Some(frame) {
      @stdio.stdout.text.write("\{frame}\n")
    }
    return status
  }
  let outcome = @cli.process_line_with_diagnostics(
    record,
    schema.value,
    options,
    format,
    schema_source=schema.source,
  )
  let report = outcome.for_line(record.line)
  if !(format is Structured) {
    write_source_diagnostics(report)
  }
  @stdio.stdout.text.write("\{report.stringify()}\n")
  outcome.status
}

///|
async fn run_batch(
  reader : &@io.BinaryReader,
  schema : LoadedSchema,
  options : @cli.Options,
  max_chars : Int32,
  registry : @repair.ToolSchemaRegistry?,
  format : @cli.DiagnosticFormat,
) -> Int32 {
  let lines = @cli.BatchLines::new(max_chars~)
  let mut status = 0
  while reader.read() is Some(chunk) {
    let mut offset = 0
    while offset < chunk.length() {
      let (next, record) = lines.next(chunk[:], offset)
      offset = next
      if record is Some(record) {
        status = @cli.merge_status(
          status,
          write_batch_line(record, schema, options, registry, format),
        )
      }
    }
  }
  if lines.finish() is Some(record) {
    status = @cli.merge_status(
      status,
      write_batch_line(record, schema, options, registry, format),
    )
  }
  @cli.batch_exit_status(options, status)
}

///|
async fn write_sse_records(records : Array[Json]) -> Unit {
  for record in records {
    @stdio.stdout.text.write("\{record.stringify()}\n")
  }
}

///|
async fn run_sse(
  reader : &@io.BinaryReader,
  schema : Json?,
  options : @cli.Options,
  max_chars : Int32,
) -> Int32 {
  let decoder = @cli.SseDecoder::new(max_chars~)
  let gateway = @cli.SseGateway::new(options, schema)
  while reader.read() is Some(chunk) {
    let mut offset = 0
    while offset < chunk.length() {
      let (next, input) = decoder.next(chunk[:], offset)
      offset = next
      if input is Some(input) {
        write_sse_records(gateway.consume(input))
        if gateway.is_done() {
          return gateway.exit_status()
        }
      }
    }
  }
  if decoder.finish() is Some(input) {
    write_sse_records(gateway.consume(input))
  }
  write_sse_records(gateway.finish(decoder.line()))
  gateway.exit_status()
}

///|
async fn run_pipe(
  reader : &@io.BinaryReader,
  schema : LoadedSchema,
  options : @cli.Options,
  max_chars : Int32,
  registry : @repair.ToolSchemaRegistry?,
  format : @cli.DiagnosticFormat,
) -> Int32 {
  if options.sse {
    run_sse(reader, schema.value, options, max_chars)
  } else {
    run_batch(reader, schema, options, max_chars, registry, format)
  }
}

///|
async fn run(options : @cli.Options, format : @cli.DiagnosticFormat) -> Int32 {
  let max_chars = @repair.RepairLimits::default().max_input
  if options.ndjson || options.sse || options.mcp_guard {
    let schema = read_schema(options.schema, max_chars)
    let registry = match options.tool_schemas {
      None => None
      Some(path) =>
        Some(
          @cli.parse_tool_schemas(
            read_path(Some(path), "tool schemas", max_chars, false),
          ),
        )
    }
    match options.input {
      None =>
        run_pipe(@stdio.stdin, schema, options, max_chars, registry, format)
      Some(path) => {
        let file = @fs.open(path[:], mode=ReadOnly) catch {
          error =>
            @cli.fail_cli("io", "could not read input: \{error.to_string()}")
        }
        defer file.close()
        run_pipe(file, schema, options, max_chars, registry, format)
      }
    }
  } else {
    let input = read_path(options.input, "input", max_chars, true)
    let prepared = match
      @cli.prepare_input_with_diagnostics(input, options, format) {
      Ok(prepared) => prepared
      Err(error) => raise @cli.CliFailure(error, 1)
    }
    let schema = read_schema(options.schema, max_chars)
    let outcome = @cli.present_with_diagnostics(
      prepared,
      schema.value,
      options,
      input,
      format,
      schema_source=schema.source,
    )
    let report = outcome.report()
    if !(format is Structured) {
      write_source_diagnostics(report)
    }
    @stdio.stdout.text.write("\{report.stringify()}\n")
    outcome.status
  }
}

///|
async fn main {
  let args = @env.args()[1:]
  let status = try {
    if args is ["-h" | "--help"] {
      @stdio.stdout.text.write("\{usage}\n")
      0
    } else {
      let (options, format) = @cli.parse_args_with_diagnostics(args)
      run(options, format)
    }
  } catch {
    @cli.CliFailure(error, status) => {
      let output : Json = { "error": error }
      write_source_diagnostics(output)
      @stdio.stderr.text.write("\{output.stringify()}\n")
      status
    }
    error => {
      let output : Json = {
        "error": { "kind": "io", "message": Json::string(error.to_string()) },
      }
      @stdio.stderr.text.write("\{output.stringify()}\n")
      1
    }
  }
  if status != 0 {
    @env.exit(status)
  }
}
