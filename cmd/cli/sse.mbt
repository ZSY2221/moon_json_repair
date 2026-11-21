///|
pub struct SseFrame {
  event_type : String
  data : String
}

///|
pub struct SseInput {
  line : Int64
  frame : Result[SseFrame, Json]
}

///|
/// A bounded SSE decoder. It keeps an unfinished physical line and one event
/// across reads, including CRLF and UTF-8 sequences split between byte chunks.
pub struct SseDecoder {
  priv line_bytes : @buffer.Buffer
  priv data : StringBuilder
  priv max_chars : Int32
  priv max_line_bytes : Int32
  priv mut line : Int64
  priv mut event_line : Int64
  priv mut event_type : String
  priv mut data_size : Int32
  priv mut has_data : Bool
  priv mut after_cr : Bool
  priv mut line_overflow : Bool
  priv mut event_error : Json?
}

///|
pub fn SseDecoder::new(max_chars~ : Int32) -> SseDecoder {
  let max_chars = max_chars.clamp(
    min=1,
    max=@repair.RepairLimits::default().max_input,
  )
  {
    line_bytes: @buffer.Buffer(),
    data: StringBuilder(),
    max_chars,
    max_line_bytes: max_chars * 3 + 3,
    line: 1L,
    event_line: 1L,
    event_type: "",
    data_size: 0,
    has_data: false,
    after_cr: false,
    line_overflow: false,
    event_error: None,
  }
}

///|
fn SseDecoder::mark_error(self : SseDecoder, error : Json) -> Unit {
  if self.event_error is None {
    self.event_error = Some(error)
  }
}

///|
fn sse_limit_error() -> Json {
  error_json("sse_event_limit", "SSE event exceeds the supported input size")
}

///|
fn SseDecoder::reset_event(self : SseDecoder) -> Unit {
  self.data.reset(keep_capacity=false)
  self.event_line = self.line
  self.event_type = ""
  self.data_size = 0
  self.has_data = false
  self.event_error = None
}

///|
fn SseDecoder::dispatch(self : SseDecoder) -> SseInput? {
  let line = self.event_line
  let input = match self.event_error {
    Some(error) => Some({ line, frame: Err(error), })
    None if self.has_data => {
      let event_type = if self.event_type.is_empty() {
        "message"
      } else {
        self.event_type
      }
      Some({ line, frame: Ok({ event_type, data: self.data.to_string(), }), })
    }
    None => None
  }
  self.reset_event()
  input
}

///|
fn SseDecoder::read_field(self : SseDecoder, line : StringView) -> Unit {
  let (key, value) = match line.find(":") {
    Some(index) => {
      let tail = line[index + 1:]
      let value = if tail.has_prefix(" ") { tail[1:] } else { tail }
      (line[:index], value)
    }
    None => (line, "")
  }
  match key {
    "data" => {
      let separator = if self.has_data { 1 } else { 0 }
      if value.length() + separator > self.max_chars - self.data_size {
        self.mark_error(sse_limit_error())
      } else {
        if self.has_data {
          self.data.write_char('\n')
        }
        self.data.write_view(value)
        self.has_data = true
        self.data_size += value.length() + separator
      }
    }
    "event" => self.event_type = value.to_owned()
    // Comments and network reconnection metadata do not affect local decoding.
    _ => ()
  }
}

///|
fn SseDecoder::end_line(self : SseDecoder) -> SseInput? {
  let line = self.line
  self.line += 1L
  if self.line_overflow {
    self.line_overflow = false
    self.mark_error(sse_limit_error())
    return None
  }
  let bytes = self.line_bytes.to_bytes()
  self.line_bytes.reset()
  let text = @utf8.decode(bytes[:], ignore_bom=line == 1L) catch {
    _ => {
      self.mark_error(error_json("sse_utf8", "SSE line must be valid UTF-8"))
      return None
    }
  }
  if text.is_empty() {
    self.dispatch()
  } else {
    if text.length() > self.max_chars {
      self.mark_error(sse_limit_error())
    } else if self.event_error is None {
      self.read_field(text[:])
    }
    None
  }
}

///|
pub fn SseDecoder::next(
  self : SseDecoder,
  chunk : BytesView,
  offset : Int32,
) -> (Int32, SseInput?) {
  let mut start = offset
  if self.after_cr && start < chunk.length() {
    self.after_cr = false
    if chunk[start] == b'\n' {
      start += 1
    }
  }
  let mut end = start
  while end < chunk.length() && chunk[end] != b'\r' && chunk[end] != b'\n' {
    end += 1
  }
  if !self.line_overflow {
    if end - start > self.max_line_bytes - self.line_bytes.length() {
      self.line_overflow = true
      self.line_bytes.reset()
    } else {
      self.line_bytes.write_bytes(chunk[start:end])
    }
  }
  if end == chunk.length() {
    (end, None)
  } else {
    self.after_cr = chunk[end] == b'\r'
    (end + 1, self.end_line())
  }
}

///|
/// A pending event at EOF is discarded as required by SSE. The CLI reports
/// the incomplete frame so strict mode can distinguish it from a clean EOF.
pub fn SseDecoder::finish(self : SseDecoder) -> SseInput? {
  let issue = match self.event_error {
    Some(error) => Some(error)
    None if self.line_overflow => Some(sse_limit_error())
    None if self.has_data || !self.line_bytes.is_empty() =>
      Some(
        error_json(
          "sse_truncated_event", "SSE event ended before its blank line",
        ),
      )
    None => None
  }
  self.line_bytes.reset()
  self.line_overflow = false
  let line = self.event_line
  self.reset_event()
  issue.map(error => { line, frame: Err(error), })
}

///|
pub fn SseDecoder::line(self : SseDecoder) -> Int64 {
  self.line
}
