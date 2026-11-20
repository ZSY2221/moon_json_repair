///|
let usage : String =
  #|Usage: moon run --target native cmd/main -- [--schema FILE] [INPUT|-]
  #|
  #|Read one UTF-8 JSON document from INPUT or from standard input.
  #|Pass --schema FILE to check the result against a strict JSON schema document.
  #|Print the repaired document and audit report as one JSON object.

///|
priv struct Options {
  input : String?
  schema : String?
}

///|
suberror CliFailure {
  CliFailure(Json, Int32)
}

///|
fn[T] fail_cli(
  kind : String,
  message : String,
  status~ : Int32 = 1,
) -> T raise CliFailure {
  raise CliFailure(
    { "kind": Json::string(kind), "message": Json::string(message) },
    status,
  )
}

///|
fn parse_args(args : ArrayView[String]) -> Options raise CliFailure {
  let mut input : String? = None
  let mut schema : String? = None
  let mut positional_only = false
  for remaining = args {
    match remaining {
      [] => break
      ["--schema", path, .. rest] if !positional_only => {
        if schema is Some(_) {
          fail_cli("usage", "--schema may only be supplied once", status=2)
        }
        schema = Some(path)
        continue rest
      }
      ["--schema"] if !positional_only =>
        fail_cli("usage", "--schema requires a file path", status=2)
      ["--", .. rest] if !positional_only => {
        positional_only = true
        continue rest
      }
      [argument, .. rest] => {
        if !positional_only && argument != "-" && argument.has_prefix("-") {
          fail_cli("usage", "unknown option \{argument}", status=2)
        }
        if input is Some(_) {
          fail_cli("usage", "expected at most one input path", status=2)
        }
        input = Some(argument)
        continue rest
      }
    }
  }
  { input: if input == Some("-") { None } else { input }, schema, }
}

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
      fail_cli("input_limit", "\{label} exceeds the supported input size")
    }
    content.write_bytes(chunk[:])
  }
  let text = @utf8.decode(content.to_bytes()[:], ignore_bom=!preserve_bom) catch {
    _ => fail_cli("invalid_utf8", "\{label} must be valid UTF-8")
  }
  if text.length() > max_chars {
    fail_cli("input_limit", "\{label} exceeds the supported input size")
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
    CliFailure(_, _) as error => raise error
    error => fail_cli("io", "could not read \{label}: \{error.to_string()}")
  }
}

///|
async fn run(options : Options) -> Int32 {
  let limits = @repair.RepairLimits::default()
  let input = read_path(options.input, "input", limits.max_input, true)
  let report = match @repair.repair(input, limits~) {
    Ok(report) => report
    Err(error) => raise CliFailure(@json.to_json(error), 1)
  }
  let (schema_report, status) : (Json, Int32) = match options.schema {
    None => (Json::null(), 0)
    Some(path) => {
      let schema_text = read_path(Some(path), "schema", limits.max_input, false)
      let schema = @json.parse(
        schema_text[:],
        max_nesting_depth=514,
        reject_duplicate_keys=true,
        preserve_number_repr=true,
      ) catch {
        error =>
          fail_cli(
            "schema_parse",
            "could not parse schema: \{error.to_string()}",
          )
      }
      let errors = @repair.validate(report.value, schema)
      let valid = errors.is_empty()
      (
        { "valid": Json::boolean(valid), "errors": @json.to_json(errors) },
        if valid {
          0
        } else {
          3
        },
      )
    }
  }
  let output : Json = {
    "json": Json::string(report.json),
    "value": report.value,
    "edits": @json.to_json(report.edits),
    "schema": schema_report,
  }
  @stdio.stdout.text.write("\{output.stringify()}\n")
  status
}

///|
async fn main {
  let args = @env.args()[1:]
  let status = try {
    if args is ["-h" | "--help"] {
      @stdio.stdout.text.write("\{usage}\n")
      0
    } else {
      run(parse_args(args))
    }
  } catch {
    CliFailure(error, status) => {
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
