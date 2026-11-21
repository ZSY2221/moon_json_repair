///|
/// Adapts the repair and validation APIs for the local browser playground.
#export_name("moonRepairPayload")
pub fn run_payload(source : String, schema_text : String) -> String {
  let outcome : Json = match @repair.repair(source) {
    Err(error) => { "ok": false, "error": @json.to_json(error) }
    Ok(report) => {
      let validation = match read_lab_schema(schema_text) {
        LabSkip => lab_skipped()
        LabInvalid(message) => lab_invalid(message)
        LabParsed(schema) => lab_checked(@repair.validate(report.value, schema))
      }
      { "ok": true, "report": @json.to_json(report), "validation": validation }
    }
  }
  outcome.stringify()
}

///|
priv enum LabSchema {
  LabSkip
  LabInvalid(String)
  LabParsed(Json)
}

///|
fn read_lab_schema(schema_text : String) -> LabSchema {
  if schema_text == "" {
    return LabSkip
  }
  LabParsed(
    @json.parse(
      schema_text[:],
      preserve_number_repr=true,
      reject_duplicate_keys=true,
    ),
  ) catch {
    error => LabInvalid(error.to_string())
  }
}

///|
fn lab_skipped() -> Json {
  { "state": "skipped" }
}

///|
fn lab_invalid(message : String) -> Json {
  { "state": "invalid_json", "message": message }
}

///|
fn lab_checked(errors : Array[@repair.ValidationError]) -> Json {
  { "state": "checked", "errors": @json.to_json(errors) }
}

///|
priv struct LabPresentation {
  schema_text : String
  schema : LabSchema
  coerce : Bool
  semantic : Bool
  diagnostics : Bool
  chinese : Bool
}

///|
fn LabPresentation::new(
  schema_text : String,
  coerce : Bool,
  semantic : Bool,
  diagnostics : Bool,
  chinese : Bool,
) -> LabPresentation {
  {
    schema_text,
    schema: read_lab_schema(schema_text),
    coerce,
    semantic,
    diagnostics,
    chinese,
  }
}

///|
fn lab_validation_diagnostic(
  source : String,
  output : String,
  edits : Array[@repair.RepairEdit],
  errors : Array[@repair.ValidationError],
  options : LabPresentation,
) -> String {
  let messages = if edits.is_empty() {
    []
  } else {
    [@repair.render_repair_audit(source, edits, chinese=options.chinese)]
  }
  let instance = []
  let schema = []
  for error in errors {
    if error.path.has_prefix("$schema") {
      schema.push(@repair.SourceDiagnostic::Schema(error))
    } else {
      instance.push(@repair.SourceDiagnostic::Schema(error))
    }
  }
  if !instance.is_empty() {
    messages.push(
      @repair.render_diagnostics(output, instance, chinese=options.chinese),
    )
  }
  if !schema.is_empty() {
    messages.push(
      @repair.render_diagnostics(
        options.schema_text,
        schema,
        chinese=options.chinese,
      ),
    )
  }
  messages.join("\n\n")
}

///|
fn lab_block(
  source : String,
  report : @repair.RepairReport,
  start : @repair.SourcePosition,
  end : @repair.SourcePosition,
  confidence : Int32,
  options : LabPresentation,
  trace : Json?,
) -> Json {
  let (output, value, coercions, validation, retry_prompt, issues) = match
    options.schema {
    LabSkip =>
      (report.json, report.value, Json::array([]), lab_skipped(), "", [])
    LabInvalid(message) =>
      (report.json, report.value, Json::array([]), lab_invalid(message), "", [])
    LabParsed(schema) => {
      let (output, value, edits, errors, retry) = if options.coerce {
        let base : @repair.CoercionOptions = {
          number_strings: true,
          boolean_strings: true,
          wrap_scalar_arrays: true,
        }
        let treatment = if options.semantic {
          @repair.coerce_with_schema_semantic(
            report.value,
            schema,
            options=base.with_semantic(),
          )
        } else {
          @repair.coerce_with_schema(report.value, schema, options=base)
        }
        let retry = if treatment.errors.is_empty() {
          ""
        } else if options.semantic {
          treatment.format_retry_prompt(schema)
        } else {
          @repair.format_retry_prompt(treatment.value, schema)
        }
        (
          treatment.json,
          treatment.value,
          @json.to_json(treatment.edits),
          treatment.errors,
          retry,
        )
      } else {
        let errors = @repair.validate(report.value, schema)
        let retry = if errors.is_empty() {
          ""
        } else {
          @repair.format_retry_prompt(report.value, schema)
        }
        (report.json, report.value, Json::array([]), errors, retry)
      }
      (output, value, edits, lab_checked(errors), retry, errors)
    }
  }
  let block : Map[String, Json] = {
    "start": @json.to_json(start),
    "end": @json.to_json(end),
    "confidence": @json.to_json(confidence),
    "report": @json.to_json(report),
    "output": output,
    "value": value,
    "coercions": coercions,
    "validation": validation,
    "retry_prompt": retry_prompt,
  }
  if trace is Some(trace) {
    block["trace"] = trace
  }
  if options.diagnostics {
    let diagnostic = lab_validation_diagnostic(
      source,
      output,
      report.edits,
      issues,
      options,
    )
    if diagnostic != "" {
      block["diagnostic"] = Json::string(diagnostic)
    }
  }
  Json::object(block)
}

///|
fn lab_response(
  result : Result[Array[Json], @repair.RepairError],
  status : @repair.StreamStatus,
  source : String,
  options : LabPresentation,
) -> String {
  let stream = @json.to_json(status)
  let payload : Json = match result {
    Err(error) => {
      let failure : Map[String, Json] = {
        "ok": false,
        "error": @json.to_json(error),
        "stream": stream,
      }
      if options.diagnostics {
        failure["diagnostic"] = Json::string(
          @repair.render_diagnostic(
            source,
            @repair.SourceDiagnostic::Repair(error),
            chinese=options.chinese,
          ),
        )
      }
      Json::object(failure)
    }
    Ok(blocks) =>
      { "ok": true, "blocks": Json::array(blocks), "stream": stream }
  }
  payload.stringify()
}

///|
fn lab_result(
  source : String,
  options : LabPresentation,
  policy : @repair.RepairPolicy,
  stream : @repair.RepairStream,
  extract : Bool,
  finalize : Bool,
  session : LabSession?,
) -> String {
  if extract {
    if finalize && !stream.status().finalized {
      ignore(stream.finalize())
    }
    return lab_response(
      @repair.extract_all_with_policy(source, policy).map(blocks => {
        let active : Map[Int32, LabBlockStream] = Map([])
        let result = blocks.map(block => {
          let trace = match session {
            None => None
            Some(session) =>
              session.block_trace(
                source,
                block.start.offset,
                block.end.offset,
                active,
              )
          }
          lab_block(
            source,
            block.report,
            block.start,
            block.end,
            block.confidence,
            options,
            trace,
          )
        })
        if session is Some(session) {
          session.blocks = active
        }
        result
      }),
      stream.status(),
      source,
      options,
    )
  }
  let (report, trace) = if session is Some(_) {
    if finalize && !stream.status().finalized {
      ignore(stream.finalize())
    }
    match stream.next_patches() {
      Ok(frame) => (Ok(frame.report), Some(lab_trace(frame)))
      Err(error) => (Err(error), None)
    }
  } else if finalize && !stream.status().finalized {
    (stream.finalize(), None)
  } else {
    (stream.preview(), None)
  }
  lab_single_response(source, options, stream, report, trace)
}

///|
fn lab_single_response(
  source : String,
  options : LabPresentation,
  stream : @repair.RepairStream,
  report : Result[@repair.RepairReport, @repair.RepairError],
  trace : Json?,
) -> String {
  let status = stream.status()
  lab_response(
    report.map(report => {
      [
        lab_block(
          source,
          report,
          { offset: 0, line: 1, column: 1, },
          status.position,
          100,
          options,
          trace,
        ),
      ]
    }),
    status,
    source,
    options,
  )
}

///|
fn lab_policy(json5 : Bool, ignore_think : Bool) -> @repair.RepairPolicy {
  let base = @repair.RepairOptions::default()
  { options: { ..base, json5, }, ignore_think_blocks: ignore_think, }
}

///|
/// Run the laboratory on a single source or extract all its candidate blocks.
#export_name("moonLabRun")
pub fn lab_run(
  source : String,
  schema : String,
  json5 : Bool,
  coerce : Bool,
  extract : Bool,
  ignore_think : Bool,
) -> String {
  lab_run_with_options(
    source, schema, json5, coerce, extract, ignore_think, false, false, false,
  )
}

///|
/// Run a laboratory repair with optional semantic coercion and localized diagnostics.
#export_name("moonLabRunWithOptions")
pub fn lab_run_with_options(
  source : String,
  schema : String,
  json5 : Bool,
  coerce : Bool,
  extract : Bool,
  ignore_think : Bool,
  semantic : Bool,
  diagnostics : Bool,
  chinese : Bool,
) -> String {
  let options = LabPresentation::new(
    schema, coerce, semantic, diagnostics, chinese,
  )
  let policy = lab_policy(json5, ignore_think)
  let stream = @repair.RepairStream::with_policy(policy)
  match stream.push(source) {
    Err(error) => lab_response(Err(error), stream.status(), source, options)
    Ok(_) => lab_result(source, options, policy, stream, extract, false, None)
  }
}

///|
priv struct LabSession {
  policy : @repair.RepairPolicy
  stream : @repair.RepairStream
  mut blocks : Map[Int32, LabBlockStream]
}

///|
priv struct LabBlockStream {
  stream : @repair.RepairStream
  mut end : Int32
}

///|
fn lab_trace(frame : @repair.PatchFrame) -> Json {
  let patches = @json.to_json(frame.patches)
  {
    "patches": patches,
    "patches_json": patches.stringify(),
    "fields": @json.to_json(frame.fields),
    "json": frame.report.json,
  }
}

///|
fn LabSession::block_trace(
  self : LabSession,
  source : String,
  start : Int32,
  end : Int32,
  active : Map[Int32, LabBlockStream],
) -> Json? {
  let block = match self.blocks.get(start) {
    Some(block) if block.end <= end => block
    _ => { end: start, stream: @repair.RepairStream::with_policy(self.policy), }
  }
  if block.stream.push(source[block.end:end].to_owned()) is Err(_) {
    return None
  }
  block.end = end
  active[start] = block
  match block.stream.next_patches() {
    Ok(frame) => Some(lab_trace(frame))
    Err(_) => None
  }
}

///|
let current_lab_session : @ref.Ref[LabSession] = {
  let policy = lab_policy(false, false)
  @ref.Ref({
    policy,
    stream: @repair.RepairStream::with_policy(policy),
    blocks: {},
  })
}

///|
/// Start a new session without carrying over the previous document or framing state.
#export_name("moonLabStreamStart")
pub fn lab_stream_start(json5 : Bool, ignore_think : Bool) -> Unit {
  let policy = lab_policy(json5, ignore_think)
  current_lab_session.val = {
    policy,
    stream: @repair.RepairStream::with_policy(policy),
    blocks: {},
  }
}

///|
/// Add one transport chunk to the active session.
#export_name("moonLabStreamPush")
pub fn lab_stream_push(chunk : String) -> Bool {
  current_lab_session.val.stream.push(chunk) is Ok(_)
}

///|
/// Publish the active stream checkpoint and audited snapshot for the lab.
#export_name("moonLabStreamView")
pub fn lab_stream_view(
  source : String,
  schema : String,
  coerce : Bool,
  extract : Bool,
  finalize : Bool,
) -> String {
  lab_stream_view_with_options(
    source, schema, coerce, extract, finalize, false, false, false,
  )
}

///|
/// Publish one laboratory snapshot with optional coercion and localized diagnostics.
#export_name("moonLabStreamViewWithOptions")
pub fn lab_stream_view_with_options(
  source : String,
  schema : String,
  coerce : Bool,
  extract : Bool,
  finalize : Bool,
  semantic : Bool,
  diagnostics : Bool,
  chinese : Bool,
) -> String {
  let session = current_lab_session.val
  let options = LabPresentation::new(
    schema, coerce, semantic, diagnostics, chinese,
  )
  lab_result(
    source,
    options,
    session.policy,
    session.stream,
    extract,
    finalize,
    Some(session),
  )
}

///|
/// Time the real repair path without serializing or updating the page.
#export_name("moonLabRepairOnly")
pub fn lab_repair_only(source : String) -> Bool {
  @repair.repair(source) is Ok(_)
}
