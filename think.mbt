///|
priv struct ThinkRange {
  start : SourcePosition
  end : SourcePosition
  closed : Bool
}

///|
// Track only enough lexical state to protect actual JSON strings and comments.
// Apostrophes in ordinary prose do not open a quoted JSON value.
priv struct ThinkLexer {
  mut frame : FrameScanner
  mut line_indent : Bool
  mut payload_start : Bool
}

///|
fn ThinkLexer::new() -> ThinkLexer {
  { frame: FrameScanner::new(256), line_indent: true, payload_start: true, }
}

///|
fn ThinkLexer::observe(
  self : ThinkLexer,
  c : Char,
  root_container~ : Bool = false,
) -> Unit {
  let frame = self.frame
  let comment = frame.mode is (FrameLineComment | FrameBlockComment) ||
    (frame.pending_slash && c is ('/' | '*')) ||
    (self.payload_start && c == '/')
  if frame.depth > 0 ||
    !(frame.mode is FrameText) ||
    frame.pending_slash ||
    root_container ||
    (self.payload_start && c is ('"' | '\'' | '/')) {
    if frame.feed(c) is FrameMismatch {
      self.frame = FrameScanner::new(256)
    }
  }
  if c is ('\r' | '\n') {
    self.line_indent = true
    if self.frame.depth == 0 && self.frame.mode is FrameText {
      self.payload_start = true
    }
  } else if !is_json_space(c) && c != '\uFEFF' {
    self.line_indent = false
    if !comment {
      self.payload_start = false
    }
  }
}

///|
fn Cursor::think_tag(self : Cursor, token : StringView) -> Bool {
  if self.offset + token.length() > self.limit {
    return false
  }
  for index in 0..<token.length() {
    let unit = self.input[self.offset + index].to_int()
    let lower = if unit >= 65 && unit <= 90 { unit + 32 } else { unit }
    if lower != token[index].to_int() {
      return false
    }
  }
  true
}

///|
priv struct ThinkQuoteBoundary {
  mut seen : Int32
  mut protects : Bool
}

///|
fn Cursor::standalone_think_close(self : Cursor) -> Bool {
  let mut next = self.offset + 8
  while char_at(self.input, next) is (' ' | '\t') {
    next += 1
  }
  next == self.limit || char_at(self.input, next) is ('\r' | '\n')
}

///|
// The first unescaped quote following the marker must disagree with the
// current string's lexical boundary before a control line can end that draft.
// Cache it so many marker-like lines in one string require just one scan.
fn Cursor::think_quote_protects(
  self : Cursor,
  quote : Char,
  boundary : ThinkQuoteBoundary,
) -> Bool {
  let begin = self.offset + 8
  if begin > boundary.seen {
    let mut offset = begin
    while offset < self.limit {
      let c = char_at(self.input, offset)
      if c == quote {
        break
      }
      offset += if c == '\\' { 2 } else { 1 }
    }
    boundary.seen = offset
    offset += 1
    while char_at(self.input, offset) is (' ' | '\t') {
      offset += 1
    }
    boundary.protects = offset >= self.limit ||
      char_at(self.input, offset) is (',' | ':' | '}' | ']' | '\r' | '\n')
  }
  boundary.protects
}

///|
fn Cursor::think_ranges(self : Cursor) -> Array[ThinkRange] {
  let ranges = []
  let outer = ThinkLexer::new()
  let double_quote = { seen: -1, protects: true, }
  let single_quote = { seen: -1, protects: true, }
  let mut inner = ThinkLexer::new()
  let mut start = self.position()
  let mut depth = 0
  while !self.at_end() {
    let c = self.peek()
    let lexer = if depth == 0 { outer } else { inner }
    if c == '<' {
      if lexer.frame.mode is FrameText && self.think_tag("<think>") {
        if depth == 0 {
          start = self.position()
          inner = ThinkLexer::new()
        }
        inner.line_indent = false
        depth += 1
        self.advance(self.offset + 7)
        continue
      }
      let close = depth > 0 &&
        self.think_tag("</think>") &&
        (match lexer.frame.mode {
          FrameText => true
          FrameString(quote) =>
            lexer.line_indent &&
            self.standalone_think_close() &&
            !self.think_quote_protects(
              quote,
              if quote == '"' {
                double_quote
              } else {
                single_quote
              },
            )
          _ => false
        })
      if close {
        depth -= 1
        self.advance(self.offset + 8)
        if depth == 0 {
          let end = self.position()
          ranges.push({ start, end, closed: true, })
          if end.line != start.line {
            outer.observe('\n')
          }
        } else if !(lexer.frame.mode is FrameText) {
          inner = ThinkLexer::new()
        }
        continue
      }
    }
    let root_container = c is ('{' | '[') &&
      lexer.frame.depth == 0 &&
      lexer.frame.mode is FrameText &&
      (
        lexer.payload_start ||
        looks_like_block(self.input, self.offset, self.json5)
      )
    lexer.observe(c, root_container~)
    self.consume(c)
  }
  if depth > 0 {
    ranges.push({ start, end: self.position(), closed: false, })
  }
  ranges
}

///|
// A same-width mask keeps parser offsets in the original UTF-16 coordinate
// space, including surrogate pairs and CRLF. Reasoning text never reaches the
// value parser and physical newlines remain visible to Markdown framing.
fn mask_think_ranges(input : String, ranges : Array[ThinkRange]) -> String {
  if ranges.is_empty() {
    return input
  }
  let source = input[:]
  let buffer = StringBuilder()
  let mut at = 0
  for range in ranges {
    buffer.write_view(source.exact_view(start=at, end=range.start.offset))
    for index in range.start.offset..<range.end.offset {
      let c = char_at(source, index)
      buffer.write_char(if c is ('\r' | '\n') { c } else { ' ' })
    }
    at = range.end.offset
  }
  buffer.write_view(source.exact_view(start=at))
  buffer.to_string()
}

///|
fn think_edit_limit(position : SourcePosition) -> RepairError {
  { kind: EditLimit, message: "repair edit limit exceeded", position, }
}

///|
// StripProse or an incomplete-member deletion may cover a masked interval.
// Split these edits so that the structural edit and the protocol audit never
// claim the same source units.
fn append_without_think_overlap(
  edits : Array[RepairEdit],
  edit : RepairEdit,
  ranges : ArrayView[ThinkRange],
) -> Unit {
  if !edit.replacement.is_empty() || edit.position.offset == edit.end_offset {
    edits.push(edit)
    return
  }
  let mut low = 0
  let mut high = ranges.length()
  let mut position = edit.position
  while low < high {
    let middle = (low + high) / 2
    if ranges[middle].end.offset <= position.offset {
      low = middle + 1
    } else {
      high = middle
    }
  }
  for i in low..<ranges.length() {
    let range = ranges[i]
    if range.start.offset >= edit.end_offset {
      break
    }
    if range.start.offset > position.offset {
      edits.push({ ..edit, position, end_offset: range.start.offset, })
    }
    position = range.end
  }
  if position.offset < edit.end_offset {
    edits.push({ ..edit, position, })
  }
}

///|
fn merge_think_audits(
  report : RepairReport,
  ranges : ArrayView[ThinkRange],
  max_edits : Int32,
) -> Result[RepairReport, RepairError] {
  if ranges.is_empty() {
    return Ok(report)
  }
  let edits = []
  for edit in report.edits {
    append_without_think_overlap(edits, edit, ranges)
  }
  for range in ranges {
    edits.push({
      kind: StripProse,
      action: if range.closed {
        "ignore think block"
      } else {
        "ignore unterminated think block"
      },
      position: range.start,
      end_offset: range.end.offset,
      replacement: "",
    })
  }
  // Preserve the original parser's ordering of insertions at the same offset.
  let ordered = edits.mapi((ordinal, edit) => (ordinal, edit))
  ordered.sort_by((left, right) => {
    let delta = left.1.position.offset.compare(right.1.position.offset)
    if delta == 0 {
      left.0.compare(right.0)
    } else {
      delta
    }
  })
  let edits = ordered.map(entry => entry.1)
  if edits.length() > max_edits {
    Err(think_edit_limit(edits[max_edits].position))
  } else {
    Ok({ ..report, edits, })
  }
}
