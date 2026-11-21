///|
/// One non-overlapping JSON payload. Source coordinates and audit positions
/// refer to the full reply. The end is exclusive. Confidence is a structural
/// heuristic from 0 to 100, never a probability of user intent.
#derive(Eq, Debug, ToJson)
pub(all) struct ExtractedBlock {
  start : SourcePosition
  end : SourcePosition
  confidence : Int32
  report : RepairReport
}

///|
priv struct ExtractionFence {
  marker : Char
  width : Int32
  label : StringView
  after : Int32
}

///|
fn fence_at(input : StringView, start : Int32) -> ExtractionFence? {
  let mut offset = start
  while char_at(input, offset) is (' ' | '\t') {
    offset += 1
  }
  let marker = char_at(input, offset)
  if !(marker is ('`' | '~')) {
    return None
  }
  let begin = offset
  while char_at(input, offset) == marker {
    offset += 1
  }
  let width = offset - begin
  if width < 3 {
    return None
  }
  let mut end = offset
  while end < input.length() && !(char_at(input, end) is ('\r' | '\n')) {
    end += 1
  }
  let label = input.exact_view(start=offset, end~).trim(chars=" \t")
  let mut after = end
  if char_at(input, after) == '\r' {
    after += 1
  }
  if char_at(input, after) == '\n' {
    after += 1
  }
  Some({ marker, width, label, after, })
}

///|
fn ExtractionFence::allows_json(self : ExtractionFence) -> Bool {
  self.label.length() == 0 ||
  self.label.equal_ignore_ascii_case("json") ||
  self.label.equal_ignore_ascii_case("json5") ||
  self.label.equal_ignore_ascii_case("jsonc") ||
  self.label.equal_ignore_ascii_case("application/json")
}

///|
priv struct ExtractionCandidate {
  start : SourcePosition
  scan : FrameScanner
  fenced : Bool
  atom : Bool
  mut previous : Char
}

///|
fn position_from(
  start : SourcePosition,
  relative : SourcePosition,
) -> SourcePosition {
  {
    offset: start.offset + relative.offset,
    line: start.line + relative.line - 1,
    column: if relative.line == 1 {
      start.column + relative.column - 1
    } else {
      relative.column
    },
  }
}

///|
fn Cursor::record_candidate(
  self : Cursor,
  blocks : Array[ExtractedBlock],
  candidate : ExtractionCandidate,
  closed : Bool,
  max_blocks : Int32,
) -> Unit raise RepairFault {
  let start = candidate.start
  let end = self.position()
  let source = self.span(start.offset, end.offset)
  let block = Cursor::new(source, self.limits, json5=self.json5)
  match block.report() {
    Ok(report) => {
      if blocks.length() >= max_blocks {
        self.reject(
          InputLimit,
          "maximum extracted block count exceeded",
          at=start,
        )
      }
      let edits = report.edits.map(edit => {
        ..edit,
        position: position_from(start, edit.position),
        end_offset: start.offset + edit.end_offset,
      })
      let base = if candidate.fenced { 100 } else { 95 }
      let missing = if closed { 0 } else { 25 }
      let penalty = if edits.length() < 10 { edits.length() * 3 } else { 30 }
      blocks.push({
        start,
        end,
        confidence: base - missing - penalty,
        report: { ..report, edits, },
      })
    }
    Err(error) =>
      if error.kind is (EditLimit | DepthLimit | InputLimit) {
        raise Fault({ ..error, position: position_from(start, error.position), })
      }
  }
}

///|
fn looks_like_block(input : StringView, offset : Int32, json5 : Bool) -> Bool {
  let mut next = offset + 1
  while is_json_space(char_at(input, next)) {
    next += 1
  }
  if char_at(input, offset) == '{' {
    return looks_like_object(input, next)
  }
  let first = char_at(input, next)
  next == input.length() ||
  first is (']' | '{' | '[' | '"' | '\'' | '-' | '/') ||
  first.is_ascii_digit() ||
  (json5 && first is ('.' | '+')) ||
  starts_literal(input, next) ||
  (
    input.length() - next < 9 &&
    literal_completion(input.exact_view(start=next)) is Some(_)
  )
}

///|
fn Cursor::read_candidates(
  self : Cursor,
  max_blocks : Int32,
) -> Array[ExtractedBlock] raise RepairFault {
  let blocks = []
  let mut fence : ExtractionFence? = None
  let mut candidate : ExtractionCandidate? = None
  let mut fence_payload_started = false
  let mut line_indent_only = true
  let mut fence_seek = FrameScanner::new(1)
  while !self.at_end() {
    let at = self.position()
    if at.column == 1 && fence_at(self.input, at.offset) is Some(marker) {
      let boundary = match fence {
        None => true
        Some(open) =>
          marker.marker == open.marker &&
          marker.width >= open.width &&
          marker.label.length() == 0
      }
      if boundary {
        if candidate is Some(active) {
          self.record_candidate(blocks, active, active.atom, max_blocks)
          candidate = None
        }
        fence = if fence is None { Some(marker) } else { None }
        fence_payload_started = false
        line_indent_only = true
        fence_seek = FrameScanner::new(1)
        self.advance(marker.after)
        continue
      }
    }
    let letter = self.peek()
    let first_content = line_indent_only
    if letter is ('\r' | '\n') {
      line_indent_only = true
    } else if !(letter is (' ' | '\t')) {
      line_indent_only = false
    }
    let fenced = fence is Some(_)
    let allow = match fence {
      Some(open) => open.allows_json()
      None => true
    }
    if !allow {
      self.bump()
      continue
    }
    if fenced && candidate is None {
      if fence_seek.mode is (FrameLineComment | FrameBlockComment) ||
        letter == '/' ||
        (fence_seek.pending_slash && letter == '*') {
        ignore(fence_seek.feed(letter))
        self.bump()
        continue
      }
      fence_seek.pending_slash = false
    }
    let opener = letter is ('{' | '[')
    let likely = opener &&
      (fenced || looks_like_block(self.input, at.offset, self.json5))
    if candidate is Some(active) {
      let atom_ends = active.atom && is_json_space(letter)
      // Recover a truncated bare object just before a new frame or prose at
      // the same indentation level. Quoted content stays with its candidate.
      // Open arrays may contain adjacent objects repaired by comma insertion.
      let may_cut = !active.fenced &&
        active.scan.depth == 1 &&
        active.scan.closers.last() == Some('}') &&
        active.scan.mode is FrameText &&
        !(active.previous is ('{' | '[' | ':' | ',')) &&
        first_content &&
        at.column <= active.start.column &&
        at.line > active.start.line
      let next_boundary = may_cut &&
        (
          likely ||
          (
            letter.is_ascii_alphabetic() &&
            !looks_like_object(self.input, at.offset)
          )
        )
      if atom_ends || next_boundary {
        self.record_candidate(blocks, active, atom_ends, max_blocks)
        candidate = None
      }
    }
    if candidate is None {
      let fenced_scalar = fenced &&
        !fence_payload_started &&
        (
          letter is ('"' | '\'') ||
          letter.is_ascii_digit() ||
          letter == '-' ||
          (self.json5 && letter is ('.' | '+')) ||
          starts_literal(self.input, at.offset) ||
          (first_content && letter is ('t' | 'f' | 'n' | 'T' | 'F' | 'N' | 'u'))
        )
      if likely || fenced_scalar {
        candidate = Some({
          start: at,
          scan: FrameScanner::new(self.limits.max_depth),
          fenced,
          atom: !opener && !(letter is ('"' | '\'')),
          previous: letter,
        })
        fence_payload_started = true
      }
    }
    self.bump()
    if candidate is Some(active) {
      match active.scan.feed(letter) {
        FrameClosed => {
          self.record_candidate(blocks, active, true, max_blocks)
          candidate = None
        }
        FrameMismatch => candidate = None
        FrameContinues =>
          if active.scan.mode is FrameText && !is_json_space(letter) {
            active.previous = letter
          }
      }
    }
  }
  if candidate is Some(active) {
    self.record_candidate(blocks, active, active.atom, max_blocks)
  }
  blocks
}

///|
/// Extract successfully repaired candidates in source order. A failed local
/// candidate is skipped. Resource limits return an error rather than hiding
/// successful blocks. Naked scalar text is ignored; language fences can frame it.
///
/// The scanner visits source code units in order. Each emitted candidate's
/// repair consumes a disjoint slice, and framing memory is bounded by max_depth.
pub fn extract_all(
  input : String,
  options : RepairOptions,
) -> Result[Array[ExtractedBlock], RepairError] {
  let limits = options.limits.normalized()
  let cursor = Cursor::new(input[:], limits, json5=options.json5)
  if cursor.invalid_input(input) is Some(error) {
    return Err(error)
  }
  let max_blocks = if options.max_blocks < 0 {
    0
  } else if options.max_blocks > 4096 {
    4096
  } else {
    options.max_blocks
  }
  Ok(cursor.read_candidates(max_blocks)) catch {
    Fault(error) => Err(error)
  }
}
