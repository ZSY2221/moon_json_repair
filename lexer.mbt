///|
priv suberror RepairFault {
  Fault(RepairError)
}

///|
priv struct Cursor {
  input : StringView
  mut limit : Int32
  mut position : SourcePosition
  mut after_cr : Bool
  edits : Array[RepairEdit]
  limits : RepairLimits
  json5 : Bool
}

///|
fn Cursor::new(
  input : StringView,
  limits : RepairLimits,
  json5~ : Bool = false,
) -> Cursor {
  {
    input,
    limit: input.length(),
    position: { offset: 0, line: 1, column: 1, },
    after_cr: false,
    edits: [],
    limits,
    json5,
  }
}

///|
fn Cursor::peek(self : Cursor, ahead~ : Int32 = 0) -> Char {
  let offset = self.position.offset + ahead
  if offset >= self.limit {
    '\u{FFFF}'
  } else {
    char_at(self.input, offset)
  }
}

///|
fn Cursor::at_end(self : Cursor) -> Bool {
  self.position.offset >= self.limit
}

///|
fn Cursor::bump(self : Cursor) -> Unit {
  let c = self.peek()
  let { offset, line, column, } = self.position
  self.position = match c {
    '\r' => { offset: offset + 1, line: line + 1, column: 1, }
    '\n' =>
      {
        offset: offset + 1,
        line: line + (if self.after_cr { 0 } else { 1 }),
        column: 1,
      }
    _ => { offset: offset + 1, line, column: column + 1, }
  }
  self.after_cr = c == '\r'
}

///|
fn Cursor::advance(self : Cursor, offset : Int32) -> Unit {
  while self.position.offset < offset {
    self.bump()
  }
}

///|
fn Cursor::span(self : Cursor, start : Int32, end : Int32) -> StringView {
  self.input.exact_view(start~, end~)
}

///|
fn Cursor::starts(self : Cursor, token : StringView) -> Bool {
  let start = self.position.offset
  start + token.length() <= self.limit && units_match(self.input, start, token)
}

///|
fn units_match(input : StringView, start : Int32, token : StringView) -> Bool {
  if start + token.length() > input.length() {
    return false
  }
  for i in 0..<token.length() {
    if input[start + i] != token[i] {
      return false
    }
  }
  true
}

///|
fn Cursor::reject(
  self : Cursor,
  kind : RepairFailureKind,
  message : String,
  at? : SourcePosition,
) -> Unit raise RepairFault {
  raise Fault({ kind, message, position: at.unwrap_or(self.position), })
}

///|
fn Cursor::edit(
  self : Cursor,
  kind : RepairKind,
  action : String,
  position : SourcePosition,
  replacement~ : String = "",
  end_offset? : Int32,
) -> Unit raise RepairFault {
  if self.edits.length() >= self.limits.max_edits {
    self.reject(EditLimit, "repair edit limit exceeded", at=position)
  }
  self.edits.push({
    kind,
    action,
    position,
    end_offset: end_offset.unwrap_or(self.position.offset),
    replacement,
  })
}

///|
fn is_json_space(c : Char) -> Bool {
  c is (' ' | '\t' | '\r' | '\n')
}

///|
fn is_identifier_start(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c is ('_' | '$')
}

///|
fn is_identifier_continue(c : Char) -> Bool {
  is_identifier_start(c) || c.is_ascii_digit() || c == '-'
}

///|
fn Cursor::skip_trivia(self : Cursor) -> Unit raise RepairFault {
  while !self.at_end() {
    let at = self.position
    if is_json_space(self.peek()) {
      self.bump()
    } else if self.starts("//") {
      self.advance(at.offset + 2)
      while !self.at_end() && !(self.peek() is ('\r' | '\n')) {
        self.bump()
      }
      self.edit(RemoveComment, "remove line comment", at)
    } else if self.starts("/*") {
      self.advance(at.offset + 2)
      while !self.at_end() && !self.starts("*/") {
        self.bump()
      }
      if !self.at_end() {
        self.advance(self.position.offset + 2)
      }
      self.edit(RemoveComment, "remove block comment", at)
    } else {
      break
    }
  }
}

///|
fn control_escape(c : Char) -> String {
  match c {
    '\n' => "\\n"
    '\r' => "\\r"
    '\t' => "\\t"
    '\u0008' => "\\b"
    '\u000C' => "\\f"
    _ => {
      let hex = "0123456789abcdef"
      let code = c.to_int()
      let high = hex[code / 16].to_int().unsafe_to_char()
      let low = hex[code % 16].to_int().unsafe_to_char()
      "\\u00\{high}\{low}"
    }
  }
}

///|
fn Cursor::unicode_escape_at(self : Cursor, offset : Int32) -> Int32 {
  if self.peek(ahead=offset) != 'u' {
    return -1
  }
  let mut unit = 0
  for i in 1..<=4 {
    let c = self.peek(ahead=offset + i)
    let digit = match c {
      '0'..<='9' => c.to_int() - '0'.to_int()
      'a'..<='f' => c.to_int() - 'a'.to_int() + 10
      'A'..<='F' => c.to_int() - 'A'.to_int() + 10
      _ => return -1
    }
    unit = unit * 16 + digit
  }
  unit
}

///|
fn Cursor::read_escape(
  self : Cursor,
  quote : Char,
  out : StringBuilder,
) -> Unit raise RepairFault {
  let at = self.position
  self.bump()
  let valid = match self.peek() {
    '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' => 1
    'u' => {
      let unit = self.unicode_escape_at(0)
      if unit < 0 || (unit >= 0xDC00 && unit <= 0xDFFF) {
        0
      } else if unit >= 0xD800 && unit <= 0xDBFF {
        let low = self.unicode_escape_at(6)
        if self.peek(ahead=5) == '\\' && low >= 0xDC00 && low <= 0xDFFF {
          11
        } else {
          0
        }
      } else {
        5
      }
    }
    _ => 0
  }
  if valid > 0 {
    self.advance(self.position.offset + valid)
    out.write_view(self.span(at.offset, self.position.offset))
  } else if quote == '\'' && self.peek() == '\'' {
    self.bump()
    out.write_char('\'')
    self.edit(
      NormalizeQuote,
      "unescape apostrophe inside converted string",
      at,
      replacement="'",
    )
  } else {
    out.write_string("\\\\")
    self.edit(
      EscapeBackslash,
      "preserve incomplete, unpaired, or unknown escape as text",
      at,
      replacement="\\\\",
    )
  }
}

///|
fn Cursor::read_string(
  self : Cursor,
  out : StringBuilder,
) -> Unit raise RepairFault {
  let open = self.position
  let quote = self.peek()
  self.bump()
  out.write_char('"')
  if quote == '\'' {
    self.edit(
      NormalizeQuote,
      "replace opening apostrophe",
      open,
      replacement="\"",
    )
  }
  let mut chunk = self.position.offset
  while !self.at_end() {
    let c = self.peek()
    if c == quote {
      let close = self.position
      out.write_view(self.span(chunk, close.offset))
      self.bump()
      out.write_char('"')
      if quote == '\'' {
        self.edit(
          NormalizeQuote,
          "replace closing apostrophe",
          close,
          replacement="\"",
        )
      }
      return
    }
    if c == '\\' || c == '"' || c.to_int() < 32 {
      let at = self.position
      out.write_view(self.span(chunk, at.offset))
      if c == '\\' {
        self.read_escape(quote, out)
      } else {
        self.bump()
        let replacement = if c == '"' { "\\\"" } else { control_escape(c) }
        out.write_string(replacement)
        if c == '"' {
          self.edit(
            NormalizeQuote,
            "escape double quote inside converted string",
            at,
            replacement~,
          )
        } else {
          self.edit(
            EscapeControl,
            "escape raw control character",
            at,
            replacement~,
          )
        }
      }
      chunk = self.position.offset
    } else {
      self.bump()
    }
  }
  out.write_view(self.span(chunk, self.position.offset))
  out.write_char('"')
  self.edit(
    CloseString,
    "close truncated string",
    self.position,
    replacement="\"",
  )
}

///|
fn Cursor::read_key(
  self : Cursor,
  out : StringBuilder,
) -> Unit raise RepairFault {
  if self.peek() is ('"' | '\'') {
    self.read_string(out)
    return
  }
  let at = self.position
  if !is_identifier_start(self.peek()) {
    self.reject(UnexpectedToken, "expected an object key")
  }
  self.bump()
  while is_identifier_continue(self.peek()) {
    self.bump()
  }
  let key = self.span(at.offset, self.position.offset)
  out.write_char('"')
  out.write_view(key)
  out.write_char('"')
  self.edit(QuoteKey, "quote bare object key", at, replacement="\"\{key}\"")
}

///|
fn Cursor::digits(self : Cursor) -> Unit {
  while self.peek().is_ascii_digit() {
    self.bump()
  }
}

///|
fn hex_digit(c : Char) -> Int32 {
  match c {
    '0'..<='9' => c.to_int() - '0'.to_int()
    'a'..<='f' => c.to_int() - 'a'.to_int() + 10
    'A'..<='F' => c.to_int() - 'A'.to_int() + 10
    _ => -1
  }
}

///|
// Multiplication by 256 stays within Int32 for base 1,000,000 limbs.
// At most 1,024 hex digits enter conversion, bounding its quadratic work.
fn decimal_from_hex(digits : StringView, negative : Bool) -> String {
  let limbs = [0]
  let base = 1_000_000
  let mut offset = 0
  while offset < digits.length() {
    let mut count = 2
    if digits.length() - offset == 1 {
      count = 1
    }
    let mut carry = 0
    for i in offset..<(offset + count) {
      carry = carry * 16 + hex_digit(char_at(digits, i))
    }
    let multiplier = if count == 2 { 256 } else { 16 }
    for i in 0..<limbs.length() {
      let value = limbs[i] * multiplier + carry
      limbs[i] = value % base
      carry = value / base
    }
    if carry != 0 {
      limbs.push(carry)
    }
    offset += count
  }
  let out = StringBuilder()
  if negative {
    out.write_char('-')
  }
  let mut index = limbs.length() - 1
  out.write_string(limbs[index].to_string())
  while index > 0 {
    index -= 1
    let digits = limbs[index].to_string()
    for _ in digits.length()..<6 {
      out.write_char('0')
    }
    out.write_string(digits)
  }
  out.to_string()
}

///|
fn invalid_number_suffix(c : Char) -> Bool {
  is_identifier_start(c) || c is ('.' | '-' | '+')
}

///|
fn Cursor::read_hex_number(
  self : Cursor,
  out : StringBuilder,
  at : SourcePosition,
  negative : Bool,
) -> Unit raise RepairFault {
  self.advance(self.position.offset + 2)
  let start = self.position.offset
  while hex_digit(self.peek()) >= 0 {
    self.bump()
    if self.position.offset - start > 1024 {
      self.reject(InvalidNumber, "hexadecimal integer exceeds 1024 digits", at~)
    }
  }
  if start == self.position.offset || invalid_number_suffix(self.peek()) {
    self.reject(InvalidNumber, "invalid hexadecimal integer", at~)
  }
  let replacement = decimal_from_hex(
    self.span(start, self.position.offset),
    negative,
  )
  out.write_string(replacement)
  self.edit(
    NormalizeLiteral,
    "convert hexadecimal integer to decimal",
    at,
    replacement~,
  )
}

///|
fn Cursor::read_number(
  self : Cursor,
  out : StringBuilder,
) -> Unit raise RepairFault {
  let at = self.position
  let sign = self.peek()
  if sign == '-' || (self.json5 && sign == '+') {
    self.bump()
  }
  if self.json5 && self.peek() == '0' && self.peek(ahead=1) is ('x' | 'X') {
    self.read_hex_number(out, at, sign == '-')
    return
  }
  let digits_start = self.position.offset
  let leading_dot = self.json5 && self.peek() == '.'
  if !leading_dot {
    match self.peek() {
      '0' => {
        self.bump()
        if self.peek().is_ascii_digit() {
          self.reject(InvalidNumber, "leading zero in number", at~)
        }
      }
      '1'..<='9' => self.digits()
      _ => self.reject(InvalidNumber, "expected a digit", at~)
    }
  }
  let mut trailing_dot = false
  if self.peek() == '.' {
    self.bump()
    if !self.peek().is_ascii_digit() {
      if !self.json5 || leading_dot {
        self.reject(InvalidNumber, "expected a fractional digit", at~)
      }
      trailing_dot = true
    } else {
      self.digits()
    }
  }
  let exponent_start = self.position.offset
  if self.peek() is ('e' | 'E') {
    self.bump()
    if self.peek() is ('+' | '-') {
      self.bump()
    }
    if !self.peek().is_ascii_digit() {
      self.reject(InvalidNumber, "expected an exponent digit", at~)
    }
    self.digits()
  }
  if invalid_number_suffix(self.peek()) {
    self.reject(InvalidNumber, "invalid character following number", at~)
  }
  if self.json5 && (sign == '+' || leading_dot || trailing_dot) {
    let normalized = StringBuilder()
    if sign == '-' {
      normalized.write_char('-')
    }
    if leading_dot {
      normalized.write_char('0')
    }
    normalized.write_view(self.span(digits_start, exponent_start))
    if trailing_dot {
      normalized.write_char('0')
    }
    normalized.write_view(self.span(exponent_start, self.position.offset))
    let replacement = normalized.to_string()
    out.write_string(replacement)
    self.edit(
      NormalizeLiteral,
      "normalize JSON5 decimal number",
      at,
      replacement~,
    )
  } else {
    out.write_view(self.span(at.offset, self.position.offset))
  }
}

///|
fn Cursor::read_literal(
  self : Cursor,
  out : StringBuilder,
) -> Unit raise RepairFault {
  let at = self.position
  while is_identifier_continue(self.peek()) {
    self.bump()
  }
  let word = self.span(at.offset, self.position.offset)
  let replacement = match word {
    "true" | "false" | "null" => {
      out.write_view(word)
      return
    }
    "True" => "true"
    "False" => "false"
    "None" | "undefined" => "null"
    _ => {
      if self.at_end() {
        if literal_completion(word) is Some(text) {
          out.write_string(text)
          self.edit(
            CompleteLiteral,
            "complete a truncated JSON literal",
            at,
            replacement=text,
          )
          return
        }
      }
      self.reject(UnexpectedToken, "unrecognized JSON literal", at~)
      return
    }
  }
  out.write_string(replacement)
  self.edit(NormalizeLiteral, "convert non-JSON literal", at, replacement~)
}

///|
fn literal_completion(word : StringView) -> String? {
  match char_at(word, 0) {
    't' => complete_literal(word, "true", "true")
    'f' => complete_literal(word, "false", "false")
    'n' => complete_literal(word, "null", "null")
    'T' => complete_literal(word, "True", "true")
    'F' => complete_literal(word, "False", "false")
    'N' => complete_literal(word, "None", "null")
    'u' => complete_literal(word, "undefined", "null")
    _ => None
  }
}

///|
fn complete_literal(
  prefix : StringView,
  spelling : StringView,
  normalized : String,
) -> String? {
  if spelling.has_prefix(prefix) {
    Some(normalized)
  } else {
    None
  }
}
