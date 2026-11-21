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
/// Append-only repair session with lexical and syntax checkpoints. Strict JSON
/// continuations reuse committed tokens. Ambiguous syntax uses the batch parser.
pub struct RepairStream {
  priv buffer : StringBuilder
  priv options : RepairOptions
  priv ignore_think_blocks : Bool
  priv incremental : Bool
  priv mut thought_checkpoint : ThinkCheckpoint?
  priv mut repair_checkpoint : RepairCheckpoint?
  priv mut scan : FrameScanner
  priv mut size : Int32
  priv mut line : Int32
  priv mut column : Int32
  priv mut after_cr : Bool
  priv mut stable_offset : Int32
  priv mut trailing : Bool
  priv mut finalized : Bool
  priv mut previous_patch : Json
  priv mut previous_hint : CheckpointPatchHint?
}

///|
/// Create a stream with standard JSON syntax and optional resource limits.
pub fn RepairStream::new(
  limits~ : RepairLimits = RepairLimits::default(),
) -> RepairStream {
  let defaults = RepairOptions::default()
  RepairStream::with_options({ ..defaults, limits, })
}

///|
/// Create a stream with the requested JSON extensions and resource limits.
pub fn RepairStream::with_options(options : RepairOptions) -> RepairStream {
  RepairStream::with_policy(options.with_ignore_think_blocks(false))
}

///|
/// Create a stream with the requested syntax and reasoning isolation policy.
pub fn RepairStream::with_policy(policy : RepairPolicy) -> RepairStream {
  RepairStream::make(policy, true)
}

///|
/// Create a reference stream that reparses each source prefix. Use it to
/// compare checkpoint results or measure the cost of full-prefix repair.
pub fn RepairStream::with_uncached_policy(
  policy : RepairPolicy,
) -> RepairStream {
  RepairStream::make(policy, false)
}

///|
fn RepairStream::make(
  policy : RepairPolicy,
  incremental : Bool,
) -> RepairStream {
  let options = policy.options
  let limits = options.limits.normalized()
  {
    buffer: StringBuilder(),
    options: { ..options, limits, },
    ignore_think_blocks: policy.ignore_think_blocks,
    incremental,
    thought_checkpoint: if policy.ignore_think_blocks {
      Some(ThinkCheckpoint::new(limits.max_depth, options.json5))
    } else {
      None
    },
    repair_checkpoint: if incremental {
      Some(RepairCheckpoint::new(limits))
    } else {
      None
    },
    scan: FrameScanner::new(limits.max_depth),
    size: 0,
    line: 1,
    column: 1,
    after_cr: false,
    stable_offset: 0,
    trailing: false,
    finalized: false,
    previous_patch: Json::null(),
    previous_hint: None,
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
  if self.repair_checkpoint is Some(checkpoint) && !checkpoint.feed(view) {
    self.repair_checkpoint = None
  }
  if self.thought_checkpoint is Some(checkpoint) {
    for index in 0..<view.length() {
      let unit = char_at(view, index)
      self.advance_position(unit)
      checkpoint.feed(unit, self.size)
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
/// Return the lexical checkpoint without scanning the accumulated source.
pub fn RepairStream::status(self : RepairStream) -> StreamStatus {
  let (frame, stable_offset, trailing) = match self.thought_checkpoint {
    Some(checkpoint) => checkpoint.framing()
    None => (self.scan, self.stable_offset, self.trailing)
  }
  let quote = match frame.mode {
    FrameString(char) => Some(char.to_string())
    _ => None
  }
  {
    position: self.position(),
    depth: frame.depth,
    stack: frame.closers.map(closer => if closer == '}' { "}" } else { "]" }),
    quote,
    in_comment: frame.mode is (FrameLineComment | FrameBlockComment),
    stable: stable_offset != 0 && !trailing && !frame.damaged,
    stable_offset,
    finalized: self.finalized,
  }
}

///|
/// Number of UTF-16 units consumed by the incremental checkpoint. Polling
/// status does not add to it. Explicit JSON previews are tracked separately.
pub fn RepairStream::scanned_units(self : RepairStream) -> Int32 {
  match self.thought_checkpoint {
    Some(checkpoint) => checkpoint.consumed
    None => self.size
  }
}

///|
/// Materialize the repaired document and audit for the accepted prefix.
/// Committed syntax can be reused, while emitting full output still costs
/// space proportional to the report.
pub fn RepairStream::preview(
  self : RepairStream,
) -> Result[RepairReport, RepairError] {
  if self.repair_checkpoint is Some(checkpoint) &&
    checkpoint.snapshot(false) is Some(snapshot) {
    return Ok(snapshot.report)
  }
  let input = self.buffer.to_string()
  if self.ignore_think_blocks {
    repair_with_policy(input, self.options.with_ignore_think_blocks(true))
  } else {
    repair_with_options(input, self.options)
  }
}

///|
/// Compute changes since the last successful patch frame. Errors leave the
/// prior baseline in place. Fields describe physical source delimiters, not
/// the synthetic delimiters used to build the preview.
pub fn RepairStream::next_patches(
  self : RepairStream,
) -> Result[PatchFrame, RepairError] {
  if self.repair_checkpoint is Some(checkpoint) &&
    checkpoint.snapshot(true) is Some(snapshot) {
    let patches = checkpoint_patches(
      self.previous_patch,
      self.previous_hint,
      snapshot,
      checkpoint,
    )
    self.previous_patch = clone_patch_value(snapshot.report.value)
    self.previous_hint = snapshot.hint
    return Ok({ patches, fields: snapshot.fields, report: snapshot.report, })
  }
  let trace = { path: "", fields: [], }
  let policy = self.options.with_ignore_think_blocks(self.ignore_think_blocks)
  repair_policy_traced(self.buffer.to_string(), policy, Some(trace)).map(report => {
    let patches = diff_json_patches(self.previous_patch, report.value)
    self.previous_patch = clone_patch_value(report.value)
    self.previous_hint = None
    { patches, fields: trace.fields, report, }
  })
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
/// Discard accepted input, current framing and previous patch history.
pub fn RepairStream::reset(self : RepairStream) -> Unit {
  self.buffer.reset(keep_capacity=false)
  self.scan = FrameScanner::new(self.options.limits.max_depth)
  if self.ignore_think_blocks {
    self.thought_checkpoint = Some(
      ThinkCheckpoint::new(self.options.limits.max_depth, self.options.json5),
    )
  }
  if self.incremental {
    self.repair_checkpoint = Some(RepairCheckpoint::new(self.options.limits))
  }
  self.size = 0
  self.line = 1
  self.column = 1
  self.after_cr = false
  self.stable_offset = 0
  self.trailing = false
  self.finalized = false
  self.previous_patch = Json::null()
  self.previous_hint = None
}
