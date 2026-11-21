///|
/// Adapts the repair and validation APIs for the local browser playground.
#export_name("moonRepairPayload")
pub fn run_payload(source : String, schema_text : String) -> String {
  let outcome : Json = match @repair.repair(source) {
    Err(error) => { "ok": false, "error": @json.to_json(error) }
    Ok(report) => {
      let validation : Json = if schema_text == "" {
        { "state": "skipped" }
      } else {
        try {
          let schema = @json.parse(
            schema_text[:],
            preserve_number_repr=true,
            reject_duplicate_keys=true,
          )
          {
            "state": "checked",
            "errors": @json.to_json(@repair.validate(report.value, schema)),
          }
        } catch {
          error => { "state": "invalid_json", "message": error.to_string() }
        }
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
fn lab_block(
  report : @repair.RepairReport,
  start : @repair.SourcePosition,
  end : @repair.SourcePosition,
  confidence : Int32,
  schema : LabSchema,
  coerce : Bool,
  trace : Json?,
) -> Json {
  let (output, value, coercions, validation, retry_prompt) = match schema {
    LabSkip => {
      let validation : Json = { "state": "skipped" }
      (report.json, report.value, Json::array([]), validation, "")
    }
    LabInvalid(message) => {
      let validation : Json = { "state": "invalid_json", "message": message }
      (report.json, report.value, Json::array([]), validation, "")
    }
    LabParsed(schema) => {
      let (output, value, edits, errors) = if coerce {
        let treatment = @repair.coerce_with_schema(report.value, schema, options={
          number_strings: true,
          boolean_strings: true,
          wrap_scalar_arrays: true,
        })
        (
          treatment.json,
          treatment.value,
          @json.to_json(treatment.edits),
          treatment.errors,
        )
      } else {
        (
          report.json,
          report.value,
          Json::array([]),
          @repair.validate(report.value, schema),
        )
      }
      let validation : Json = {
        "state": "checked",
        "errors": @json.to_json(errors),
      }
      let retry = if errors.is_empty() {
        ""
      } else {
        @repair.format_retry_prompt(value, schema)
      }
      (output, value, edits, validation, retry)
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
  Json::object(block)
}

///|
fn lab_response(
  result : Result[Array[Json], @repair.RepairError],
  status : @repair.StreamStatus,
) -> String {
  let stream = @json.to_json(status)
  let payload : Json = match result {
    Err(error) =>
      { "ok": false, "error": @json.to_json(error), "stream": stream }
    Ok(blocks) =>
      { "ok": true, "blocks": Json::array(blocks), "stream": stream }
  }
  payload.stringify()
}

///|
fn lab_result(
  source : String,
  schema_text : String,
  policy : @repair.RepairPolicy,
  stream : @repair.RepairStream,
  coerce : Bool,
  extract : Bool,
  finalize : Bool,
  session : LabSession?,
) -> String {
  let schema = read_lab_schema(schema_text)
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
            block.report,
            block.start,
            block.end,
            block.confidence,
            schema,
            coerce,
            trace,
          )
        })
        if session is Some(session) {
          session.blocks = active
        }
        result
      }),
      stream.status(),
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
  let status = stream.status()
  lab_response(
    report.map(report => {
      [
        lab_block(
          report,
          { offset: 0, line: 1, column: 1, },
          status.position,
          100,
          schema,
          coerce,
          trace,
        ),
      ]
    }),
    status,
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
  let policy = lab_policy(json5, ignore_think)
  let stream = @repair.RepairStream::with_policy(policy)
  match stream.push(source) {
    Err(error) => lab_response(Err(error), stream.status())
    Ok(_) =>
      lab_result(source, schema, policy, stream, coerce, extract, false, None)
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
  let session = current_lab_session.val
  lab_result(
    source,
    schema,
    session.policy,
    session.stream,
    coerce,
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
