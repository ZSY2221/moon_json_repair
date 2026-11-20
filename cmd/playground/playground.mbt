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
  {
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
  options : @repair.RepairOptions,
  stream : @repair.RepairStream,
  coerce : Bool,
  extract : Bool,
  finalize : Bool,
) -> String {
  let schema = read_lab_schema(schema_text)
  if extract {
    if finalize && !stream.status().finalized {
      ignore(stream.finalize())
    }
    return lab_response(
      @repair.extract_all(source, options).map(blocks => {
        blocks.map(block => {
          lab_block(
            block.report,
            block.start,
            block.end,
            block.confidence,
            schema,
            coerce,
          )
        })
      }),
      stream.status(),
    )
  }
  let report = if finalize && !stream.status().finalized {
    stream.finalize()
  } else {
    stream.preview()
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
        ),
      ]
    }),
    status,
  )
}

///|
fn lab_options(json5 : Bool) -> @repair.RepairOptions {
  let base = @repair.RepairOptions::default()
  { ..base, json5, }
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
) -> String {
  let options = lab_options(json5)
  let stream = @repair.RepairStream::with_options(options)
  match stream.push(source) {
    Err(error) => lab_response(Err(error), stream.status())
    Ok(_) => lab_result(source, schema, options, stream, coerce, extract, false)
  }
}

///|
priv struct LabSession {
  options : @repair.RepairOptions
  stream : @repair.RepairStream
}

///|
let current_lab_session : @ref.Ref[LabSession] = {
  let options = lab_options(false)
  @ref.Ref({ options, stream: @repair.RepairStream::with_options(options), })
}

///|
/// Start a new session without carrying over the previous document or framing state.
#export_name("moonLabStreamStart")
pub fn lab_stream_start(json5 : Bool) -> Unit {
  let options = lab_options(json5)
  current_lab_session.val = {
    options,
    stream: @repair.RepairStream::with_options(options),
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
  let { options, stream, } = current_lab_session.val
  lab_result(source, schema, options, stream, coerce, extract, finalize)
}

///|
/// Time the real repair path without serializing or updating the page.
#export_name("moonLabRepairOnly")
pub fn lab_repair_only(source : String) -> Bool {
  @repair.repair(source) is Ok(_)
}
