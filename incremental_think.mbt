///|
// Incrementally recognize the same plausible JSON root starts used by the
// batch filter. During a probe, whitespace and bare-key characters cannot
// alter the shield's quote, container, or comment state.
priv enum ThinkRootProbe {
  ProbeNone
  ObjectKey
  ObjectWord
  ObjectColon
  ArrayValue
  ArrayWord(StringView, Int32)
}

///|
priv struct ThinkShield {
  lexer : ThinkLexer
  mut root : ThinkRootProbe
  json5 : Bool
}

///|
fn ThinkShield::new(json5 : Bool) -> ThinkShield {
  { lexer: ThinkLexer::new(), root: ProbeNone, json5, }
}

///|
fn FrameScanner::checkpoint_copy(self : FrameScanner) -> FrameScanner {
  { ..self, closers: self.closers.copy(), }
}

///|
fn ThinkShield::checkpoint_copy(self : ThinkShield) -> ThinkShield {
  {
    ..self,
    lexer: { ..self.lexer, frame: self.lexer.frame.checkpoint_copy(), },
  }
}

///|
fn think_literal_prefix(unit : Char) -> StringView? {
  match unit {
    't' => Some("true")
    'f' => Some("false")
    'n' => Some("null")
    'T' => Some("True")
    'F' => Some("False")
    'N' => Some("None")
    'u' => Some("undefined")
    _ => None
  }
}

///|
fn ThinkShield::confirm_root(self : ThinkShield, opener : Char) -> Unit {
  self.root = ProbeNone
  ignore(self.lexer.frame.feed(opener))
}

///|
fn ThinkShield::consume_probe(self : ThinkShield, unit : Char) -> Unit {
  match self.root {
    ProbeNone => ()
    ObjectKey =>
      if !is_json_space(unit) {
        if unit is ('}' | '/' | '"' | '\'') {
          self.confirm_root('{')
        } else {
          self.root = if is_identifier_start(unit) {
            ObjectWord
          } else {
            ProbeNone
          }
        }
      }
    ObjectWord =>
      if is_json_space(unit) {
        self.root = ObjectColon
      } else if unit is (':' | '/') {
        self.confirm_root('{')
      } else if !is_identifier_continue(unit) {
        self.root = ProbeNone
      }
    ObjectColon =>
      if !is_json_space(unit) {
        if unit is (':' | '/') {
          self.confirm_root('{')
        } else {
          self.root = ProbeNone
        }
      }
    ArrayValue =>
      if !is_json_space(unit) {
        if unit is (']' | '{' | '[' | '"' | '\'' | '-' | '/') ||
          unit.is_ascii_digit() ||
          (self.json5 && unit is ('.' | '+')) {
          self.confirm_root('[')
        } else if think_literal_prefix(unit) is Some(word) {
          self.root = ArrayWord(word, 1)
        } else {
          self.root = ProbeNone
        }
      }
    ArrayWord(word, index) =>
      if index == word.length() {
        if !is_identifier_continue(unit) {
          self.confirm_root('[')
        } else {
          self.root = ProbeNone
        }
      } else if word[index].to_int() == unit.to_int() {
        self.root = ArrayWord(word, index + 1)
      } else {
        self.root = ProbeNone
      }
  }
}

///|
fn ThinkShield::observe(self : ThinkShield, unit : Char) -> Unit {
  self.consume_probe(unit)
  let root_container = if unit is ('{' | '[') &&
    self.lexer.frame.mode is FrameText &&
    self.lexer.frame.depth == 0 {
    if self.lexer.payload_start {
      true
    } else {
      self.root = if unit == '{' { ObjectKey } else { ArrayValue }
      false
    }
  } else {
    false
  }
  self.lexer.observe(unit, root_container~)
}

///|
priv struct ThinkVisible {
  frame : FrameScanner
  mut stable_offset : Int32
  mut trailing : Bool
}

///|
fn ThinkVisible::observe(self : ThinkVisible, unit : Char, end : Int32) -> Unit {
  if self.stable_offset != 0 && !is_json_space(unit) {
    self.trailing = true
  }
  if self.frame.feed(unit) is FrameClosed &&
    self.stable_offset == 0 &&
    !self.frame.damaged {
    self.stable_offset = end
  }
}

///|
priv struct ThinkTagMatch {
  mut token : StringView
  mut length : Int32
  opening : Bool
  closing : Bool
  quote : Char?
}

///|
priv struct ThinkPath {
  outer : ThinkShield
  mut draft : ThinkShield
  visible : ThinkVisible
  mut marker : ThinkTagMatch?
  mut depth : Int32
  mut masked_line : Bool
  json5 : Bool
}

///|
fn ThinkPath::new(max_depth : Int32, json5 : Bool) -> ThinkPath {
  {
    outer: ThinkShield::new(json5),
    draft: ThinkShield::new(json5),
    visible: {
      frame: FrameScanner::new(max_depth),
      stable_offset: 0,
      trailing: false,
    },
    marker: None,
    depth: 0,
    masked_line: false,
    json5,
  }
}

///|
fn ThinkPath::checkpoint_copy(self : ThinkPath) -> ThinkPath {
  {
    ..self,
    outer: self.outer.checkpoint_copy(),
    draft: self.draft.checkpoint_copy(),
    visible: { ..self.visible, frame: self.visible.frame.checkpoint_copy(), },
  }
}

///|
fn ThinkPath::enter(self : ThinkPath) -> Unit {
  if self.depth == 0 {
    self.draft = ThinkShield::new(self.json5)
    self.masked_line = false
  }
  self.draft.lexer.line_indent = false
  self.depth += 1
}

///|
fn ThinkPath::leave(self : ThinkPath, quote_recovery : Bool) -> Unit {
  self.depth -= 1
  if self.depth == 0 {
    if self.masked_line {
      self.outer.observe('\n')
    }
  } else if quote_recovery {
    self.draft = ThinkShield::new(self.json5)
  }
}

///|
fn ThinkPath::record_visible(
  self : ThinkPath,
  unit : Char,
  end : Int32,
) -> Unit {
  if self.depth == 0 {
    self.visible.observe(unit, end)
  } else if unit is ('\r' | '\n') {
    self.masked_line = true
    self.visible.observe(unit, end)
  }
}

///|
fn ThinkPath::begin_marker(
  self : ThinkPath,
  shield : ThinkShield,
  end : Int32,
) -> Bool {
  // A less-than sign fixes the interpretation of any bare root probe, even
  // when a following tag will be masked from the visible JSON stream.
  shield.consume_probe('<')
  let opening = shield.lexer.frame.mode is FrameText
  let quote = match shield.lexer.frame.mode {
    FrameString(quote) if shield.lexer.line_indent => Some(quote)
    _ => None
  }
  let closing = self.depth > 0 && (opening || quote is Some(_))
  if !opening && !closing {
    return false
  }
  // An unfinished opening marker counts as visible trailing text for queries,
  // but its first code unit has the same framing effect as masked whitespace.
  if self.depth == 0 {
    self.visible.observe(' ', end)
  }
  self.marker = Some({ token: "", length: 1, opening, closing, quote, })
  true
}

///|
fn ThinkTagMatch::advance(self : ThinkTagMatch, unit : Char) -> Bool {
  if self.length == 1 {
    if unit == '/' && self.closing {
      self.token = "</think>"
    } else if self.opening {
      self.token = "<think>"
    } else {
      return false
    }
  }
  let code = unit.to_int()
  let lower = if code >= 65 && code <= 90 { code + 32 } else { code }
  if lower != self.token[self.length].to_int() {
    return false
  }
  self.length += 1
  true
}

///|
fn ThinkPath::literal_marker(
  self : ThinkPath,
  shield : ThinkShield,
  marker : ThinkTagMatch,
) -> Unit {
  shield.observe('<')
  // Only the slash and the first following letter can affect lexical state.
  if marker.token == "</think>" && marker.length > 1 {
    shield.observe('/')
    if marker.length > 2 {
      shield.observe('t')
    }
  }
  if self.depth == 0 && self.visible.stable_offset != 0 {
    self.visible.trailing = true
  }
}

///|
// Returns the quote kind only when an otherwise valid close may be an
// independent control line inside a malformed draft string.
fn ThinkPath::feed(self : ThinkPath, unit : Char, end : Int32) -> Char? {
  let shield = if self.depth == 0 { self.outer } else { self.draft }
  if self.marker is Some(marker) {
    if marker.advance(unit) {
      if marker.length == marker.token.length() {
        self.marker = None
        if marker.token == "<think>" {
          self.enter()
        } else if marker.quote is Some(_) {
          self.literal_marker(shield, marker)
          return marker.quote
        } else {
          self.leave(false)
        }
      }
      return None
    }
    self.marker = None
    self.literal_marker(shield, marker)
  }
  if unit == '<' && self.begin_marker(shield, end) {
    return None
  }
  shield.observe(unit)
  self.record_visible(unit, end)
  None
}

///|
priv enum ThinkClosePhase {
  OwnLine
  FindQuote
  SkipEscaped
  QuoteBoundary
}

///|
priv enum ThinkResolution {
  Hold
  Retain
  Resume
}

///|
priv struct ThinkPendingClose {
  candidate : ThinkPath
  quote : Char
  mut phase : ThinkClosePhase
}

///|
fn ThinkPendingClose::observe(
  self : ThinkPendingClose,
  unit : Char,
) -> ThinkResolution {
  match self.phase {
    OwnLine =>
      if unit is ('\r' | '\n') {
        self.phase = FindQuote
      } else if !(unit is (' ' | '\t')) {
        return Retain
      }
    FindQuote =>
      if unit == self.quote {
        self.phase = QuoteBoundary
      } else if unit == '\\' {
        self.phase = SkipEscaped
      }
    SkipEscaped => self.phase = FindQuote
    QuoteBoundary =>
      if !(unit is (' ' | '\t')) {
        return if unit is (',' | ':' | '}' | ']' | '\r' | '\n') {
          Retain
        } else {
          Resume
        }
      }
  }
  Hold
}

///|
priv struct ThinkCheckpoint {
  mut current : ThinkPath
  mut pending : ThinkPendingClose?
  mut consumed : Int32
}

///|
fn ThinkCheckpoint::new(max_depth : Int32, json5 : Bool) -> ThinkCheckpoint {
  { current: ThinkPath::new(max_depth, json5), pending: None, consumed: 0, }
}

///|
fn ThinkCheckpoint::feed(
  self : ThinkCheckpoint,
  unit : Char,
  end : Int32,
) -> Unit {
  self.consumed += 1
  let possible = self.current.feed(unit, end)
  match self.pending {
    Some(pending) => {
      ignore(pending.candidate.feed(unit, end))
      match pending.observe(unit) {
        Hold => ()
        Retain => self.pending = None
        Resume => {
          self.current = pending.candidate
          self.pending = None
        }
      }
    }
    None =>
      if possible is Some(quote) {
        let candidate = self.current.checkpoint_copy()
        candidate.leave(true)
        self.pending = Some({ candidate, quote, phase: OwnLine, })
      }
  }
}

///|
fn ThinkCheckpoint::framing(
  self : ThinkCheckpoint,
) -> (FrameScanner, Int32, Bool) {
  let path = self.current
  let state = path.visible
  let trailing = state.trailing || (path.depth == 0 && path.marker is Some(_))
  (state.frame, state.stable_offset, trailing)
}
