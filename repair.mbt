///|
priv struct FenceLine {
  start : Int32
  after : Int32
}

///|
// A fence marker occupies a line and is optionally labeled json.
fn find_fence(
  input : StringView,
  start : Int32,
  closing : Bool,
  json5~ : Bool = false,
) -> FenceLine? {
  let mut line = start
  while line < input.length() {
    let mut end = line
    while end < input.length() &&
          input[end].to_int() != 10 &&
          input[end].to_int() != 13 {
      end += 1
    }
    let mut after = end
    if after < input.length() && input[after].to_int() == 13 {
      after += 1
    }
    if after < input.length() && input[after].to_int() == 10 {
      after += 1
    }
    let marker = input.exact_view(start=line, end~).trim(chars=" \t")
    if marker == "```" ||
      (
        !closing &&
        (
          marker.equal_ignore_ascii_case("```json") ||
          (json5 && marker.equal_ignore_ascii_case("```json5"))
        )
      ) {
      return Some({ start: line, after, })
    }
    line = after
  }
  None
}

///|
fn char_at(input : StringView, offset : Int32) -> Char {
  if offset < input.length() {
    let code = input[offset].to_int()
    if code >= 0xD800 && code <= 0xDFFF {
      '\u0080'
    } else {
      code.unsafe_to_char()
    }
  } else {
    '\u{FFFF}'
  }
}

///|
fn starts_literal(input : StringView, at : Int32) -> Bool {
  match char_at(input, at) {
    't' => word_at(input, at, "true")
    'f' => word_at(input, at, "false")
    'n' => word_at(input, at, "null")
    'T' => word_at(input, at, "True")
    'F' => word_at(input, at, "False")
    'N' => word_at(input, at, "None")
    'u' => word_at(input, at, "undefined")
    _ => false
  }
}

///|
fn word_at(input : StringView, at : Int32, word : StringView) -> Bool {
  let end = at + word.length()
  units_match(input, at, word) && !is_identifier_continue(char_at(input, end))
}

///|
fn numbered_preamble(input : StringView, start : Int32) -> Bool {
  let mut end = start
  while char_at(input, end).is_ascii_digit() {
    end += 1
  }
  end > start &&
  char_at(input, end) is ('.' | ')') &&
  is_json_space(char_at(input, end + 1))
}

///|
fn value_starts(c : Char) -> Bool {
  c.is_ascii_digit() ||
  c is ('{' | '[' | '"' | '\'' | '-' | 't' | 'f' | 'n' | 'T' | 'F' | 'N' | 'u')
}

///|
fn key_starts(c : Char) -> Bool {
  c is ('"' | '\'') || is_identifier_start(c)
}

///|
fn looks_like_object(input : StringView, start : Int32) -> Bool {
  let first = char_at(input, start)
  if start == input.length() || first is ('}' | '/' | '"' | '\'') {
    return true
  }
  if !is_identifier_start(first) {
    return false
  }
  let mut end = start + 1
  while is_identifier_continue(char_at(input, end)) {
    end += 1
  }
  while is_json_space(char_at(input, end)) {
    end += 1
  }
  end == input.length() || char_at(input, end) is (':' | '/')
}

///|
fn find_container(
  input : StringView,
  start : Int32,
  json5~ : Bool = false,
) -> Int32? {
  // The same end of a whitespace run can be used for consecutive candidates.
  let mut next = start
  for i in start..<input.length() {
    let c = char_at(input, i)
    if !(c is ('{' | '[')) {
      continue
    }
    if next <= i {
      next = i + 1
      while is_json_space(char_at(input, next)) {
        next += 1
      }
    }
    let first = char_at(input, next)
    let eof = next == input.length()
    if (c == '{' && looks_like_object(input, next)) ||
      (
        c == '[' &&
        (
          eof ||
          first is (']' | '{' | '[' | '"' | '\'' | '-' | '/') ||
          (json5 && first is ('.' | '+')) ||
          first.is_ascii_digit() ||
          starts_literal(input, next)
        )
      ) {
      return Some(i)
    }
  }
  None
}

///|
fn Cursor::read_value(
  self : Cursor,
  out : StringBuilder,
  depth : Int32,
) -> Unit raise RepairFault {
  match self.peek() {
    '{' | '[' as opener => {
      if depth >= self.limits.max_depth {
        self.reject(DepthLimit, "maximum JSON nesting depth exceeded")
      }
      self.bump()
      out.write_char(opener)
      if opener == '{' {
        self.read_object(out, depth + 1)
      } else {
        self.read_array(out, depth + 1)
      }
    }
    '"' | '\'' => self.read_string(out)
    '0'..<='9' | '-' => self.read_number(out)
    '+' | '.' if self.json5 => self.read_number(out)
    c =>
      if is_identifier_start(c) {
        self.read_literal(out)
      } else {
        self.reject(UnexpectedToken, "expected a JSON value")
      }
  }
}

///|
priv enum Separator {
  EndContainer
  ExplicitComma(SourcePosition)
  MissingComma
}

///|
fn Cursor::separator(
  self : Cursor,
  closer : Char,
  can_start : (Char) -> Bool,
) -> Separator raise RepairFault {
  self.skip_trivia()
  if self.at_end() || self.peek() == closer {
    return EndContainer
  }
  let at = self.position()
  if self.peek() == ',' {
    self.bump()
    self.skip_trivia()
    if self.at_end() || self.peek() == closer {
      self.edit(
        RemoveTrailingComma,
        "remove trailing comma",
        at,
        end_offset=at.offset + 1,
      )
      return EndContainer
    }
    ExplicitComma(at)
  } else if can_start(self.peek()) {
    MissingComma
  } else {
    self.reject(
      UnexpectedToken,
      "expected a comma or matching closing delimiter",
    )
    EndContainer
  }
}

///|
fn Cursor::close_container(
  self : Cursor,
  out : StringBuilder,
  closer : Char,
) -> Unit raise RepairFault {
  if self.at_end() {
    if closer == ']' {
      self.edit(
        CloseArray,
        "close truncated array",
        self.position(),
        replacement="]",
      )
    } else {
      self.edit(
        CloseObject,
        "close truncated object",
        self.position(),
        replacement="}",
      )
    }
  } else {
    self.bump()
  }
  out.write_char(closer)
}

///|
fn Cursor::read_array(
  self : Cursor,
  out : StringBuilder,
  depth : Int32,
) -> Unit raise RepairFault {
  self.skip_trivia()
  if !self.at_end() && self.peek() != ']' {
    while true {
      self.read_value(out, depth)
      match
        self.separator(']', c => {
          value_starts(c) || (self.json5 && c is ('.' | '+'))
        }) {
        EndContainer => break
        ExplicitComma(_) => ()
        MissingComma =>
          self.edit(
            InsertComma,
            "insert missing comma",
            self.position(),
            replacement=",",
          )
      }
      out.write_char(',')
    }
  }
  self.close_container(out, ']')
}

///|
fn Cursor::drop_member(
  self : Cursor,
  at : SourcePosition,
) -> Unit raise RepairFault {
  // Replace speculative edits within the discarded member by one deletion.
  while self.edits.last() is Some(edit) && edit.position.offset >= at.offset {
    ignore(self.edits.pop())
  }
  self.edit(
    DropIncompleteMember,
    "drop final object member without a value",
    at,
  )
}

///|
fn Cursor::read_object(
  self : Cursor,
  out : StringBuilder,
  depth : Int32,
) -> Unit raise RepairFault {
  let seen : Set[String] = Set([])
  let key_buffer = StringBuilder()
  self.skip_trivia()
  let mut preceding = EndContainer
  while !self.at_end() && self.peek() != '}' {
    let key_at = self.position()
    let member_at = match preceding {
      ExplicitComma(at) => at
      MissingComma => {
        self.edit(InsertComma, "insert missing comma", key_at, replacement=",")
        key_at
      }
      EndContainer => key_at
    }
    key_buffer.reset()
    self.read_key(key_buffer)
    self.skip_trivia()
    if self.at_end() {
      self.drop_member(member_at)
      break
    }
    if self.peek() != ':' {
      self.reject(UnexpectedToken, "expected a colon after the object key")
    }
    let key_json = key_buffer.to_string()
    let key = try @json.parse(key_json[:]) catch {
      _ => {
        self.reject(
          UnexpectedToken,
          "object key cannot be decoded as JSON",
          at=key_at,
        )
        return
      }
    } noraise {
      String(text) => text
      _ => abort("object key lexer must produce a string")
    }
    if seen.contains(key) {
      self.reject(DuplicateKey, "duplicate object key", at=key_at)
    }
    self.bump()
    self.skip_trivia()
    if self.at_end() {
      self.drop_member(member_at)
      break
    }
    if !seen.is_empty() {
      out.write_char(',')
    }
    seen.add(key)
    out.write_string(key_json)
    out.write_char(':')
    self.read_value(out, depth)
    preceding = self.separator('}', key_starts)
    if preceding is EndContainer {
      break
    }
  }
  self.close_container(out, '}')
}

///|
fn Cursor::finish_prose(self : Cursor, allow : Bool) -> Unit raise RepairFault {
  self.skip_trivia()
  if self.at_end() {
    return
  }
  let at = self.position()
  let c = self.peek()
  let remaining = self.span(0, self.limit)
  if !allow ||
    (
      value_starts(c) &&
      (!is_identifier_start(c) || starts_literal(remaining, at.offset))
    ) ||
    !(c.is_ascii_alphabetic() ||
    c.to_int() > 127 ||
    c is ('.' | '!' | ';' | '*' | '(')) ||
    (self.json5 && c is ('.' | '+') && self.peek(ahead=1).is_ascii_digit()) ||
    find_container(remaining, at.offset, json5=self.json5) is Some(_) ||
    find_fence(remaining, at.offset, false, json5=self.json5) is Some(_) {
    self.reject(
      TrailingContent,
      "ambiguous or unexpected content after the JSON value",
    )
  }
  self.advance(self.limit)
  self.edit(StripProse, "remove text after JSON", at)
}

///|
fn Cursor::read_document(self : Cursor) -> String raise RepairFault {
  if self.peek() == '\uFEFF' {
    let at = self.position()
    self.bump()
    self.edit(StripBom, "remove leading Unicode BOM", at)
  }
  self.skip_trivia()
  if self.at_end() {
    self.reject(EmptyInput, "expected a JSON value")
  }

  let start = self.position()
  let first = self.peek()
  let is_root = first is ('{' | '[' | '"' | '\'' | '-') ||
    (self.json5 && first is ('.' | '+') && self.peek(ahead=1).is_ascii_digit()) ||
    (first.is_ascii_digit() && !numbered_preamble(self.input, start.offset)) ||
    starts_literal(self.input, start.offset)
  let mut closing : FenceLine? = None
  if !is_root {
    match find_fence(self.input, start.offset, false, json5=self.json5) {
      Some(open) => {
        self.advance(open.start)
        if start.offset != open.start {
          self.edit(StripProse, "remove text before JSON", start)
        }
        let marker = self.position()
        self.advance(open.after)
        self.edit(StripFence, "remove opening Markdown fence", marker)
        closing = find_fence(self.input, open.after, true)
        if closing is Some(close) {
          self.limit = close.start
        }
        self.skip_trivia()
      }
      None =>
        match find_container(self.input, start.offset, json5=self.json5) {
          Some(at) => {
            self.advance(at)
            self.edit(StripProse, "remove text before JSON", start)
          }
          None => ()
        }
    }
  }
  if self.at_end() {
    self.reject(EmptyInput, "expected a JSON value after removing the wrapper")
  }
  let structured = self.peek() is ('{' | '[')
  let out = StringBuilder()
  self.read_value(out, 0)
  self.finish_prose(structured)
  if closing is Some(close) {
    self.limit = self.input.length()
    let marker = self.position()
    self.advance(close.after)
    self.edit(StripFence, "remove closing Markdown fence", marker)
    self.finish_prose(true)
  }
  out.to_string()
}

///|
fn RepairLimits::normalized(self : RepairLimits) -> RepairLimits {
  {
    max_input: if self.max_input < 0 {
      0
    } else {
      self.max_input
    },
    max_depth: if self.max_depth < 1 {
      1
    } else if self.max_depth > 256 {
      256
    } else {
      self.max_depth
    },
    max_edits: if self.max_edits < 0 {
      0
    } else {
      self.max_edits
    },
  }
}

///|
fn input_limit_error(position : SourcePosition) -> RepairError {
  { kind: InputLimit, message: "maximum JSON input size exceeded", position, }
}

///|
// JavaScript callers can supply strings with lone UTF-16 surrogate units.
// Check them before using scalar-boundary StringView slices.
fn invalid_utf16_at(input : String) -> Int32? {
  let mut offset = 0
  while offset < input.length() {
    let unit = input[offset].to_int()
    if unit >= 0xD800 && unit <= 0xDFFF {
      if unit >= 0xDC00 || offset + 1 == input.length() {
        return Some(offset)
      }
      let next = input[offset + 1].to_int()
      if next < 0xDC00 || next > 0xDFFF {
        return Some(offset)
      }
      offset += 2
    } else {
      offset += 1
    }
  }
  None
}

///|
/// Repair one JSON document and record the edits against the original input.
/// Ambiguous values such as duplicate keys and malformed numbers return Err.
pub fn repair(
  input : String,
  limits~ : RepairLimits = RepairLimits::default(),
) -> Result[RepairReport, RepairError] {
  repair_input(input, limits, false)
}

///|
/// Repair one document, with extensions enabled only when explicitly requested.
pub fn repair_with_options(
  input : String,
  options : RepairOptions,
) -> Result[RepairReport, RepairError] {
  repair_input(input, options.limits, options.json5)
}

///|
fn repair_input(
  input : String,
  limits : RepairLimits,
  json5 : Bool,
) -> Result[RepairReport, RepairError] {
  let limits = limits.normalized()
  let cursor = Cursor::new(input[:], limits, json5~)
  if cursor.invalid_input(input) is Some(error) {
    return Err(error)
  }
  cursor.report()
}

///|
fn Cursor::invalid_input(cursor : Cursor, input : String) -> RepairError? {
  if input.length() > cursor.limits.max_input {
    return Some(input_limit_error(cursor.position()))
  }
  if invalid_utf16_at(input) is Some(offset) {
    cursor.advance(offset)
    return Some({
      kind: InvalidUnicode,
      message: "expected well-formed UTF-16 input",
      position: cursor.position(),
    })
  }
  None
}

///|
fn Cursor::report(cursor : Cursor) -> Result[RepairReport, RepairError] {
  let json = cursor.read_document() catch { Fault(error) => return Err(error) }
  let value = @json.parse(
    json[:],
    max_nesting_depth=cursor.limits.max_depth + 1,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ =>
      return Err({
        kind: UnexpectedToken,
        message: "repaired document cannot be decoded as JSON",
        position: cursor.position(),
      })
  }
  Ok({ json, value, edits: cursor.edits, })
}
