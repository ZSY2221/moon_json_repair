///|
let usage : String =
  #|Usage: moon run --target native cmd/main -- [OPTIONS] [INPUT|-]
  #|
  #|Read one UTF-8 JSON document from INPUT or from standard input.
  #|  --schema FILE    Check against a strict JSON schema document.
  #|  --ndjson         Process each physical line and continue after line errors.
  #|  --extract-all    Return all repairable JSON blocks.
  #|  --ignore-think   Skip reasoning blocks before repairing JSON.
  #|  --coerce         Coerce schema-typed numeric and Boolean strings.
  #|  --retry-prompt   Include a repair prompt for schema errors.
  #|  --strict-exit    Return 1 for rejected batch lines or 3 for schema errors.
  #|
  #|--coerce and --retry-prompt require --schema.

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
async fn read_schema(path : String?, max_chars : Int32) -> Json? {
  match path {
    None => None
    Some(path) =>
      Some(@cli.parse_schema(read_path(Some(path), "schema", max_chars, false)))
  }
}

///|
async fn write_batch_line(
  record : @cli.BatchLine,
  schema : Json?,
  options : @cli.Options,
) -> Int32 {
  let outcome = @cli.process_line(record, schema, options)
  @stdio.stdout.text.write("\{outcome.for_line(record.line).stringify()}\n")
  outcome.status
}

///|
async fn run_batch(
  reader : &@io.BinaryReader,
  schema : Json?,
  options : @cli.Options,
  max_chars : Int32,
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
          write_batch_line(record, schema, options),
        )
      }
    }
  }
  if lines.finish() is Some(record) {
    status = @cli.merge_status(
      status,
      write_batch_line(record, schema, options),
    )
  }
  @cli.batch_exit_status(options, status)
}

///|
async fn run(options : @cli.Options) -> Int32 {
  let max_chars = @repair.RepairLimits::default().max_input
  if options.ndjson {
    let schema = read_schema(options.schema, max_chars)
    match options.input {
      None => run_batch(@stdio.stdin, schema, options, max_chars)
      Some(path) => {
        let file = @fs.open(path[:], mode=ReadOnly) catch {
          error =>
            @cli.fail_cli("io", "could not read input: \{error.to_string()}")
        }
        defer file.close()
        run_batch(file, schema, options, max_chars)
      }
    }
  } else {
    let input = read_path(options.input, "input", max_chars, true)
    let prepared = match @cli.prepare_input(input, options) {
      Ok(prepared) => prepared
      Err(error) => raise @cli.CliFailure(error, 1)
    }
    let outcome = @cli.present(
      prepared,
      read_schema(options.schema, max_chars),
      options,
    )
    @stdio.stdout.text.write("\{outcome.report().stringify()}\n")
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
      run(@cli.parse_args(args))
    }
  } catch {
    @cli.CliFailure(error, status) => {
      let output : Json = { "error": error }
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
