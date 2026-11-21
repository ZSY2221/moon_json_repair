///|
/// The source boundary observed so far. Stack entries are expected closing
/// delimiters from outermost to innermost, capped by max_depth. A stable
/// boundary describes balanced framing, not successful JSON or schema parsing.
#derive(Eq, Debug, ToJson)
pub(all) struct StreamStatus {
  position : SourcePosition
  depth : Int32
  stack : Array[String]
  quote : String?
  in_comment : Bool
  stable : Bool
  stable_offset : Int32
  finalized : Bool
}

///|
/// One append-only buffer and a lexical framing checkpoint. Preview and
/// finalize run the authoritative syntax repair. With reasoning isolation,
/// status scans the masked prefix to handle tags split across any pushes.
pub struct RepairStream {
  priv buffer : StringBuilder
  priv options : RepairOptions
  priv ignore_think_blocks : Bool
  priv mut scan : FrameScanner
  priv mut size : Int32
  priv mut line : Int32
  priv mut column : Int32
  priv mut after_cr : Bool
  priv mut stable_offset : Int32
  priv mut trailing : Bool
  priv mut finalized : Bool
}

///|
pub fn RepairStream::new(
  limits~ : RepairLimits = RepairLimits::default(),
) -> RepairStream {
  let defaults = RepairOptions::default()
  RepairStream::with_options({ ..defaults, limits, })
}

///|
pub fn RepairStream::with_options(options : RepairOptions) -> RepairStream {
  RepairStream::with_policy(options.with_ignore_think_blocks(false))
}

///|
pub fn RepairStream::with_policy(policy : RepairPolicy) -> RepairStream {
  let options = policy.options
  let limits = options.limits.normalized()
  {
    buffer: StringBuilder(),
    options: { ..options, limits, },
    ignore_think_blocks: policy.ignore_think_blocks,
    scan: FrameScanner::new(limits.max_depth),
    size: 0,
    line: 1,
    column: 1,
    after_cr: false,
    stable_offset: 0,
    trailing: false,
    finalized: false,
  }
}

///|
fn RepairStream::position(self : RepairStream) -> SourcePosition {
  { offset: self.size, line: self.line, column: self.column, }
}

///|
fn RepairStream::advance_position(self : RepairStream, unit : Char) -> Unit {
  self.size += 1
  match unit {
    '\r' => {
      self.line += 1
      self.column = 1
    }
    '\n' => {
      if !self.after_cr {
        self.line += 1
      }
      self.column = 1
    }
    _ => self.column += 1
  }
  self.after_cr = unit == '\r'
}

///|
fn RepairStream::observe(self : RepairStream, unit : Char) -> Unit {
  if self.stable_offset != 0 && !is_json_space(unit) {
    self.trailing = true
  }
  self.advance_position(unit)
  match self.scan.feed(unit) {
    FrameClosed if self.stable_offset == 0 && !self.scan.damaged =>
      self.stable_offset = self.size
    _ => ()
  }
}

///|
// Ordinary string units leave the framing state untouched. Only quotes,
// escapes and line breaks need to pass through observe one at a time.
fn plain_string_end(view : StringView, start : Int32, quote : Char) -> Int32 {
  let mut end = start
  let delimiter = quote.to_int()
  while end < view.length() {
    let unit = view[end].to_int()
    if unit == delimiter ||
      unit == '\\'.to_int() ||
      unit == '\r'.to_int() ||
      unit == '\n'.to_int() {
      break
    }
    end += 1
  }
  end
}

///|
/// Append a chunk atomically. On overflow the previously accepted prefix
/// remains available to preview, extend, or reset.
pub fn RepairStream::push(
  self : RepairStream,
  chunk : String,
) -> Result[Unit, RepairError] {
  if self.finalized {
    return Err({
      kind: UnexpectedToken,
      message: "stream is finalized; reset it before pushing",
      position: self.position(),
    })
  }
  if chunk.length() > self.options.limits.max_input - self.size {
    return Err(input_limit_error(self.position()))
  }
  self.buffer.write_string(chunk)
  let view = chunk[:]
  if self.ignore_think_blocks {
    for index in 0..<view.length() {
      self.advance_position(char_at(view, index))
    }
  } else {
    self.observe_chunk(view)
  }
  Ok(())
}

///|
fn RepairStream::observe_chunk(self : RepairStream, view : StringView) -> Unit {
  let mut index = 0
  while index < view.length() {
    let end = match self.scan.mode {
      FrameString(quote) if !self.scan.escaped && self.stable_offset == 0 =>
        plain_string_end(view, index, quote)
      _ => index
    }
    if end == index {
      self.observe(char_at(view, index))
      index += 1
    } else {
      let units = end - index
      self.size += units
      self.column += units
      self.after_cr = false
      index = end
    }
  }
}

///|
/// Return the lexical checkpoint. The default path uses incremental framing.
/// Opting into reasoning isolation recomputes framing from the masked prefix.
pub fn RepairStream::status(self : RepairStream) -> StreamStatus {
  if self.ignore_think_blocks && self.size != 0 {
    let input = self.buffer.to_string()
    let cursor = Cursor::new(input[:], self.options.limits)
    let masked = mask_think_ranges(input, cursor.think_ranges())
    let scan = RepairStream::with_options(self.options)
    scan.observe_chunk(masked[:])
    scan.finalized = self.finalized
    return scan.status()
  }
  let quote = match self.scan.mode {
    FrameString(char) => Some(char.to_string())
    _ => None
  }
  {
    position: self.position(),
    depth: self.scan.depth,
    stack: self.scan.closers.map(closer => closer.to_string()),
    quote,
    in_comment: self.scan.mode is (FrameLineComment | FrameBlockComment),
    stable: self.stable_offset != 0 && !self.trailing && !self.scan.damaged,
    stable_offset: self.stable_offset,
    finalized: self.finalized,
  }
}

///|
pub fn RepairStream::preview(
  self : RepairStream,
) -> Result[RepairReport, RepairError] {
  let input = self.buffer.to_string()
  if self.ignore_think_blocks {
    repair_with_policy(input, self.options.with_ignore_think_blocks(true))
  } else {
    repair_with_options(input, self.options)
  }
}

///|
/// Seal the source and produce the same result as a batch repair of all chunks.
/// Subsequent pushes fail until reset; the lexical source state stays visible.
pub fn RepairStream::finalize(
  self : RepairStream,
) -> Result[RepairReport, RepairError] {
  self.finalized = true
  self.preview()
}

///|
pub fn RepairStream::reset(self : RepairStream) -> Unit {
  self.buffer.reset(keep_capacity=false)
  self.scan = FrameScanner::new(self.options.limits.max_depth)
  self.size = 0
  self.line = 1
  self.column = 1
  self.after_cr = false
  self.stable_offset = 0
  self.trailing = false
  self.finalized = false
}
