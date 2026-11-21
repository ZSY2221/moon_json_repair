///|
#derive(Eq, Hash)
priv struct SseCallKey {
  provider : String
  message_id : String
  choice_index : Int32
  index : Int32
}

///|
priv struct SseToolCall {
  key : SseCallKey
  mut stream : @repair.RepairStream?
  mut id : String
  mut name : String
  mut initial : String?
  mut chars : Int32
  mut seq : Int64
  mut previous : Json
}

///|
let sse_max_calls : Int32 = 256

///|
let sse_max_argument_units : Int32 = 8 * 1_048_576

///|
let sse_max_metadata_units : Int32 = 4_096

///|
/// Translate provider SSE events into independent tool-call streams and reports.
pub struct SseGateway {
  priv options : Options
  priv schema : Json?
  priv policy : @repair.RepairPolicy
  priv calls : Map[SseCallKey, SseToolCall]
  priv order : Array[SseToolCall]
  priv mut openai_id : String
  priv mut anthropic_id : String
  priv mut units : Int32
  priv mut status : Int32
  priv mut done : Bool
}

///|
/// Start an SSE session with optional schema validation for each call.
pub fn SseGateway::new(options : Options, schema : Json?) -> SseGateway {
  {
    options,
    schema,
    policy: cli_policy(options),
    calls: {},
    order: [],
    openai_id: "",
    anthropic_id: "",
    units: 0,
    status: 0,
    done: false,
  }
}

///|
/// Test whether the provider sent its terminal sentinel.
pub fn SseGateway::is_done(self : SseGateway) -> Bool {
  self.done
}

///|
/// Return the accumulated strict exit status for the session.
pub fn SseGateway::exit_status(self : SseGateway) -> Int32 {
  batch_exit_status(self.options, self.status)
}

///|
fn SseToolCall::identity(self : SseToolCall) -> Json {
  let fields : Map[String, Json] = {
    "provider": Json::string(self.key.provider),
    "index": @json.to_json(self.key.index),
  }
  if !self.key.message_id.is_empty() {
    fields["message_id"] = Json::string(self.key.message_id)
  }
  if !self.id.is_empty() {
    fields["id"] = Json::string(self.id)
  }
  if !self.name.is_empty() {
    fields["name"] = Json::string(self.name)
  }
  if self.key.choice_index >= 0 {
    fields["choice_index"] = @json.to_json(self.key.choice_index)
  }
  Json::object(fields)
}

///|
fn SseGateway::error(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  error : Json,
  call? : SseToolCall,
) -> Unit {
  let fields : Map[String, Json] = { "event": "error", "error": error }
  if call is Some(call) {
    fields["call"] = call.identity()
  }
  let outcome : Outcome = { fields, status: 1, }
  outputs.push(outcome.for_line(line))
  self.status = 1
}

///|
fn SseGateway::tool(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  key : SseCallKey,
) -> SseToolCall? {
  if self.calls.get(key) is Some(call) {
    return Some(call)
  }
  if self.order.length() >= sse_max_calls {
    self.error(
      outputs,
      line,
      error_json("sse_call_limit", "too many SSE tool calls"),
    )
    return None
  }
  let call = {
    key,
    stream: Some(@repair.RepairStream::with_policy(self.policy)),
    id: "",
    name: "",
    initial: None,
    chars: 0,
    seq: 0L,
    previous: Json::null(),
  }
  self.calls[key] = call
  self.order.push(call)
  Some(call)
}

///|
fn SseGateway::retire(self : SseGateway, call : SseToolCall) -> Unit {
  self.units -= call.chars + call.initial.map(s => s.length()).unwrap_or(0)
  call.stream = None
  call.chars = 0
  call.initial = None
  call.previous = Json::null()
}

///|
fn SseGateway::render(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  call : SseToolCall,
  report : @repair.RepairReport,
  patch_frame : @repair.PatchFrame?,
  reason : String?,
) -> Unit {
  let outcome = present_report(report, self.schema, self.options)
  let fields = outcome.fields
  call.seq += 1L
  fields["call"] = call.identity()
  fields["seq"] = Json::number(call.seq.to_double(), repr=call.seq.to_string())
  match reason {
    Some(reason) => {
      fields["event"] = "tool_call"
      fields["finish_reason"] = Json::string(reason)
      self.status = merge_status(self.status, outcome.status)
    }
    None => fields["event"] = "patch"
  }
  if patch_frame is Some(frame) {
    let value = fields["value"]
    let patches = if self.options.coerce {
      let patches = @repair.diff_json_patches(call.previous, value)
      call.previous = value
      patches
    } else {
      frame.patches
    }
    fields["patches"] = @json.to_json(patches)
    fields["fields"] = @json.to_json(frame.fields)
  }
  outputs.push(outcome.for_line(line))
}

///|
fn SseGateway::update(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  call : SseToolCall,
  fragment : String,
) -> Unit {
  if fragment.is_empty() {
    return
  }
  guard call.stream is Some(stream) else {
    self.error(
      outputs,
      line,
      error_json(
        "sse_after_finish", "argument delta arrived after the tool call finished",
      ),
      call~,
    )
    return
  }
  self.units -= call.initial.map(s => s.length()).unwrap_or(0)
  call.initial = None
  if fragment.length() > sse_max_argument_units - self.units {
    self.error(
      outputs,
      line,
      error_json(
        "sse_argument_budget", "pending tool arguments exceed the stream budget",
      ),
      call~,
    )
    self.retire(call)
    return
  }
  match stream.push(fragment) {
    Err(error) => {
      self.error(outputs, line, @json.to_json(error), call~)
      self.retire(call)
    }
    Ok(_) => {
      call.chars += fragment.length()
      self.units += fragment.length()
      // Incomplete previews can fail until another provider chunk arrives.
      // Only final failures contribute to the process status.
      if self.options.emit_patches && stream.next_patches() is Ok(frame) {
        self.render(outputs, line, call, frame.report, Some(frame), None)
      }
    }
  }
}

///|
fn SseGateway::close_call(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  call : SseToolCall,
  reason : String,
) -> Unit {
  guard call.stream is Some(stream) else { return }
  if call.initial is Some(initial) && stream.push(initial) is Err(error) {
    self.error(outputs, line, @json.to_json(error), call~)
    self.retire(call)
    return
  }
  match stream.finalize() {
    Ok(report) =>
      if self.options.emit_patches {
        match stream.next_patches() {
          Ok(frame) =>
            self.render(outputs, line, call, report, Some(frame), Some(reason))
          Err(error) => self.error(outputs, line, @json.to_json(error), call~)
        }
      } else {
        self.render(outputs, line, call, report, None, Some(reason))
      }
    Err(error) => self.error(outputs, line, @json.to_json(error), call~)
  }
  self.retire(call)
}

///|
fn sse_text(fields : Map[String, Json], name : String) -> String {
  if fields.get(name) is Some(String(value)) {
    value
  } else {
    ""
  }
}

///|
fn sse_index(value : Json?) -> Int32? {
  if value is Some(Number(number, repr~)) &&
    !(repr is Some(raw) &&
    (raw.contains(".") || raw.contains("e") || raw.contains("E"))) &&
    number >= 0.0 &&
    number <= 2_147_483_647.0 {
    let index = number.to_int()
    if index.to_double() == number {
      return Some(index)
    }
  }
  None
}

///|
fn sse_shape_error(message : String) -> Json {
  error_json("sse_payload", message)
}

///|
fn sse_metadata_error() -> Json {
  error_json(
    "sse_metadata_limit", "provider ID or tool name exceeds the supported size",
  )
}

///|
fn SseGateway::openai_call(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  choice_index : Int32,
  item : Json,
) -> Unit {
  guard item is Object(fields) && sse_index(fields.get("index")) is Some(index) else {
    self.error(
      outputs,
      line,
      sse_shape_error("tool call requires a nonnegative index"),
    )
    return
  }
  let (name, arguments) = match fields.get("function") {
    None | Some(Null) => ("", "")
    Some(Object(function)) => {
      let fragment = match function.get("arguments") {
        None | Some(Null) => ""
        Some(String(fragment)) => fragment
        _ => {
          self.error(
            outputs,
            line,
            sse_shape_error("tool call arguments must be a string"),
          )
          return
        }
      }
      (sse_text(function, "name"), fragment)
    }
    _ => {
      self.error(
        outputs,
        line,
        sse_shape_error("tool call function must be an object"),
      )
      return
    }
  }
  let id = sse_text(fields, "id")
  if id.length() > sse_max_metadata_units ||
    name.length() > sse_max_metadata_units {
    self.error(outputs, line, sse_metadata_error())
    return
  }
  let key = {
    provider: "openai_chat_completions",
    message_id: self.openai_id,
    choice_index,
    index,
  }
  guard self.tool(outputs, line, key) is Some(call) else { return }
  if (!id.is_empty() && !call.id.is_empty() && call.id != id) ||
    (!name.is_empty() && !call.name.is_empty() && call.name != name) {
    self.error(
      outputs,
      line,
      error_json(
        "sse_call_identity", "tool identity changed for the same index",
      ),
      call~,
    )
    self.retire(call)
    return
  }
  if !id.is_empty() {
    call.id = id
  }
  if !name.is_empty() {
    call.name = name
  }
  self.update(outputs, line, call, arguments)
}

///|
fn SseGateway::openai_event(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  data : Map[String, Json],
  choices : Array[Json],
) -> Unit {
  let id = sse_text(data, "id")
  if id.length() > sse_max_metadata_units {
    self.error(outputs, line, sse_metadata_error())
    return
  }
  if !id.is_empty() {
    self.openai_id = id
  }
  if choices.length() > sse_max_calls {
    self.error(outputs, line, sse_shape_error("too many choices in one event"))
    return
  }
  let mut remaining = sse_max_calls
  for choice in choices {
    guard choice is Object(fields) &&
      sse_index(fields.get("index")) is Some(choice_index) else {
      self.error(
        outputs,
        line,
        sse_shape_error("each choice requires a nonnegative index"),
      )
      continue
    }
    // Content and reasoning fields are separate provider channels. Only
    // function.arguments strings are allowed into the tool-argument stream.
    match fields.get("delta") {
      None | Some(Null) => ()
      Some(Object(delta)) =>
        match delta.get("tool_calls") {
          None | Some(Null) => ()
          Some(Array(calls)) if calls.length() <= remaining => {
            remaining -= calls.length()
            for call in calls {
              self.openai_call(outputs, line, choice_index, call)
            }
          }
          _ =>
            self.error(
              outputs,
              line,
              sse_shape_error("tool_calls must be a bounded array"),
            )
        }
      _ =>
        self.error(
          outputs,
          line,
          sse_shape_error("choice delta must be an object"),
        )
    }
    if fields.get("finish_reason") is Some(String(reason)) {
      for call in self.order {
        if call.key.provider == "openai_chat_completions" &&
          call.key.message_id == self.openai_id &&
          call.key.choice_index == choice_index {
          self.close_call(outputs, line, call, reason)
        }
      }
    }
  }
}

///|
fn SseGateway::anthropic_key(self : SseGateway, index : Int32) -> SseCallKey {
  {
    provider: "anthropic_messages",
    message_id: self.anthropic_id,
    choice_index: -1,
    index,
  }
}

///|
fn SseGateway::anthropic_start(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  data : Map[String, Json],
) -> Unit {
  guard data.get("content_block") is Some(Object(block)) &&
    sse_text(block, "type") == "tool_use" else {
    return
  }
  guard sse_index(data.get("index")) is Some(index) else {
    self.error(
      outputs,
      line,
      sse_shape_error("tool_use block requires a nonnegative index"),
    )
    return
  }
  let key = self.anthropic_key(index)
  if self.calls.contains(key) {
    self.error(
      outputs,
      line,
      sse_shape_error("duplicate tool_use content block"),
    )
    return
  }
  let id = sse_text(block, "id")
  let name = sse_text(block, "name")
  if id.length() > sse_max_metadata_units ||
    name.length() > sse_max_metadata_units {
    self.error(outputs, line, sse_metadata_error())
    return
  }
  guard self.tool(outputs, line, key) is Some(call) else { return }
  call.id = id
  call.name = name
  // The starting empty input is a placeholder once deltas arrive. If the
  // provider supplies no deltas, retain its initial input on block stop.
  let initial = match block.get("input") {
    Some(Object(_) as input) => input.stringify()
    None => "{}"
    _ => {
      self.error(
        outputs,
        line,
        sse_shape_error("initial tool input must be an object"),
        call~,
      )
      self.retire(call)
      return
    }
  }
  if initial.length() > sse_max_argument_units - self.units {
    self.error(
      outputs,
      line,
      error_json(
        "sse_argument_budget", "pending tool arguments exceed the stream budget",
      ),
      call~,
    )
    self.retire(call)
    return
  }
  self.units += initial.length()
  call.initial = Some(initial)
}

///|
fn SseGateway::anthropic_delta(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  data : Map[String, Json],
) -> Unit {
  guard data.get("delta") is Some(Object(delta)) &&
    sse_text(delta, "type") == "input_json_delta" else {
    return
  }
  guard sse_index(data.get("index")) is Some(index) &&
    delta.get("partial_json") is Some(String(fragment)) else {
    self.error(
      outputs,
      line,
      sse_shape_error("input_json_delta requires an index and a string"),
    )
    return
  }
  if self.tool(outputs, line, self.anthropic_key(index)) is Some(call) {
    self.update(outputs, line, call, fragment)
  }
}

///|
fn SseGateway::anthropic_event(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  data : Map[String, Json],
  event_type : String,
) -> Unit {
  match event_type {
    "message_start" =>
      if data.get("message") is Some(Object(msg)) {
        let id = sse_text(msg, "id")
        if id.length() > sse_max_metadata_units {
          self.error(outputs, line, sse_metadata_error())
        } else {
          self.anthropic_id = id
        }
      }
    "content_block_start" => self.anthropic_start(outputs, line, data)
    "content_block_delta" => self.anthropic_delta(outputs, line, data)
    "content_block_stop" =>
      if sse_index(data.get("index")) is Some(index) {
        if self.calls.get(self.anthropic_key(index)) is Some(call) {
          self.close_call(outputs, line, call, event_type)
        }
      } else {
        self.error(
          outputs,
          line,
          sse_shape_error("content_block_stop requires an index"),
        )
      }
    "message_stop" => self.finish_into(outputs, line, event_type)
    _ => ()
  }
}

///|
fn SseGateway::event(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  frame : SseFrame,
) -> Unit {
  if frame.data[:].trim() == "[DONE]" {
    self.finish_into(outputs, line, "done")
    return
  }
  let data = @json.parse(
    frame.data[:],
    max_nesting_depth=64,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ => {
      self.error(
        outputs,
        line,
        error_json("sse_json", "SSE data must be valid JSON"),
      )
      return
    }
  }
  guard data is Object(fields) else {
    self.error(
      outputs,
      line,
      sse_shape_error("SSE provider message must be an object"),
    )
    return
  }
  let event_type = sse_text(fields, "type")
  if fields.contains("error") ||
    event_type == "error" ||
    frame.event_type == "error" {
    self.error(
      outputs,
      line,
      error_json("sse_provider", "upstream reported a streaming error"),
    )
    return
  }
  match fields.get("choices") {
    Some(Array(choices)) => self.openai_event(outputs, line, fields, choices)
    Some(_) =>
      self.error(outputs, line, sse_shape_error("choices must be an array"))
    None =>
      self.anthropic_event(
        outputs,
        line,
        fields,
        if event_type.is_empty() {
          frame.event_type
        } else {
          event_type
        },
      )
  }
}

///|
/// Apply an SSE event or framing error and return newly available reports.
pub fn SseGateway::consume(self : SseGateway, input : SseInput) -> Array[Json] {
  let outputs = []
  if !self.done {
    match input.frame {
      Ok(frame) => self.event(outputs, input.line, frame)
      Err(error) => self.error(outputs, input.line, error)
    }
  }
  outputs
}

///|
fn SseGateway::finish_into(
  self : SseGateway,
  outputs : Array[Json],
  line : Int64,
  reason : String,
) -> Unit {
  if !self.done {
    self.done = true
    for call in self.order {
      self.close_call(outputs, line, call, reason)
    }
  }
}

///|
/// Close any remaining calls and return their final reports.
pub fn SseGateway::finish(self : SseGateway, line : Int64) -> Array[Json] {
  let outputs = []
  self.finish_into(outputs, line, "eof")
  outputs
}
