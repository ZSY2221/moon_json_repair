///|
priv struct SdkSession {
  stream : @repair.RepairStream
  presentation : LabPresentation
  source : StringBuilder?
}

///|
let sdk_sessions : Map[Int32, SdkSession] = Map([])

///|
let next_sdk_id : @ref.Ref[Int32] = @ref.Ref(1)

///|
fn claim_sdk_id() -> Int32 {
  let mut id = next_sdk_id.val
  while sdk_sessions.contains(id) {
    id = if id == 2147483647 { 1 } else { id + 1 }
  }
  next_sdk_id.val = if id == 2147483647 { 1 } else { id + 1 }
  id
}

///|
/// Open an independent SDK stream and return its per-instance handle.
#export_name("moonSdkStreamStart")
pub fn sdk_stream_start(
  schema : String,
  json5 : Bool,
  coerce : Bool,
  ignore_think : Bool,
  semantic : Bool,
  diagnostics : Bool,
  chinese : Bool,
) -> Int32 {
  let id = claim_sdk_id()
  sdk_sessions[id] = {
    stream: @repair.RepairStream::with_policy(lab_policy(json5, ignore_think)),
    presentation: LabPresentation::new(
      schema, coerce, semantic, diagnostics, chinese,
    ),
    source: if diagnostics {
      Some(StringBuilder())
    } else {
      None
    },
  }
  id
}

///|
fn SdkSession::input(self : SdkSession) -> String {
  match self.source {
    Some(source) => source.to_string()
    None => ""
  }
}

///|
/// Append a transport chunk and return the new stream status without a preview.
#export_name("moonSdkStreamPush")
pub fn sdk_stream_push(id : Int32, chunk : String) -> String {
  guard sdk_sessions.get(id) is Some(session) else { return "" }
  match session.stream.push(chunk) {
    Err(error) =>
      lab_response(
        Err(error),
        session.stream.status(),
        session.input(),
        session.presentation,
      )
    Ok(_) => {
      if session.source is Some(source) {
        source.write_string(chunk)
      }
      let response : Json = {
        "ok": true,
        "stream": @json.to_json(session.stream.status()),
      }
      response.stringify()
    }
  }
}

///|
/// Render a preview, consume the next patch frame, or finalize this SDK stream.
#export_name("moonSdkStreamView")
pub fn sdk_stream_view(id : Int32, patches : Bool, finalize : Bool) -> String {
  guard sdk_sessions.get(id) is Some(session) else { return "" }
  let (report, trace) = if finalize {
    (session.stream.finalize(), None)
  } else if patches {
    match session.stream.next_patches() {
      Ok(frame) => (Ok(frame.report), Some(lab_trace(frame)))
      Err(error) => (Err(error), None)
    }
  } else {
    (session.stream.preview(), None)
  }
  lab_single_response(
    session.input(),
    session.presentation,
    session.stream,
    report,
    trace,
  )
}

///|
/// Release retained source and patch history for an SDK stream handle.
#export_name("moonSdkStreamClose")
pub fn sdk_stream_close(id : Int32) -> Unit {
  ignore(sdk_sessions.remove(id))
}
