///|
priv enum CheckpointPhase {
  FirstItem
  AfterItem
  AfterComma(SourcePosition)
  AfterKey
  AfterColon
}

///|
priv struct CheckpointContainer {
  object : Bool
  path : String
  entries : Array[(String, Json)]
  seen : Set[String]
  mut phase : CheckpointPhase
  mut key : String
  mut key_json : String
  mut member_at : SourcePosition
}

///|
priv enum CheckpointEscape {
  PlainText
  EscapeStart
  HexDigits(Int32, Int32, Int32)
  LowSlash(Int32)
  LowU(Int32)
}

///|
priv struct CheckpointString {
  key : Bool
  path : String
  start : Int32
  lexeme : StringBuilder
  decoded : StringBuilder
  raw_escape : StringBuilder
  mut escape_at : SourcePosition
  mut escape : CheckpointEscape
  mut raw_high : Int32
}

///|
priv enum CheckpointToken {
  NoToken
  QuotedToken(CheckpointString)
  BareToken(StringBuilder)
}

///|
// The checkpoint recognizes strict JSON and synthesizes the same ending the
// repair parser would append. Ambiguous spelling and repair paths use Cursor.
priv struct RepairCheckpoint {
  max_depth : Int32
  max_edits : Int32
  output : StringBuilder
  fields : Array[FieldSeal]
  edits : Array[RepairEdit]
  containers : Array[CheckpointContainer]
  mut root : Json?
  mut token : CheckpointToken
  mut offset : Int32
  mut line : Int32
  mut column : Int32
  mut after_cr : Bool
}

///|
fn RepairCheckpoint::new(limits : RepairLimits) -> RepairCheckpoint {
  {
    max_depth: limits.max_depth,
    max_edits: limits.max_edits,
    output: StringBuilder(),
    fields: [],
    edits: [],
    containers: [],
    root: None,
    token: NoToken,
    offset: 0,
    line: 1,
    column: 1,
    after_cr: false,
  }
}

///|
fn RepairCheckpoint::position(self : RepairCheckpoint) -> SourcePosition {
  { offset: self.offset, line: self.line, column: self.column, }
}

///|
fn RepairCheckpoint::advance(self : RepairCheckpoint, unit : Int32) -> Unit {
  self.offset += 1
  if unit == 13 || unit == 10 {
    if unit == 13 || !self.after_cr {
      self.line += 1
    }
    self.column = 1
  } else {
    self.column += 1
  }
  self.after_cr = unit == 13
}

///|
fn CheckpointContainer::next_key(self : CheckpointContainer) -> String {
  if self.object {
    self.key
  } else {
    self.entries.length().to_string()
  }
}

///|
fn RepairCheckpoint::begin_value(self : RepairCheckpoint) -> String {
  if self.containers.last() is Some(parent) {
    if !parent.entries.is_empty() {
      self.output.write_char(',')
    }
    if parent.object {
      self.output.write_string(parent.key_json)
      self.output.write_char(':')
    }
    pointer_child(parent.path, parent.next_key())
  } else {
    ""
  }
}

///|
fn RepairCheckpoint::commit(
  self : RepairCheckpoint,
  value : Json,
  path : String,
) -> Unit {
  self.fields.push({ pointer: path, is_sealed: true, })
  if self.containers.last() is Some(parent) {
    parent.entries.push((parent.next_key(), value))
    parent.phase = AfterItem
  } else {
    self.root = Some(value)
  }
}

///|
fn CheckpointContainer::value(
  self : CheckpointContainer,
  tail : Json?,
  copy : Bool,
) -> Json {
  if self.object {
    let members : Map[String, Json] = Map([])
    for pair in self.entries {
      let (key, value) = pair
      members[key] = if copy { clone_patch_value(value) } else { value }
    }
    if tail is Some(last) {
      members[self.key] = last
    }
    Json::object(members)
  } else {
    let items = self.entries.map(pair => {
      if copy {
        clone_patch_value(pair.1)
      } else {
        pair.1
      }
    })
    if tail is Some(last) {
      items.push(last)
    }
    Json::array(items)
  }
}

///|
fn checkpoint_removed_comma(at : SourcePosition) -> RepairEdit {
  {
    kind: RemoveTrailingComma,
    action: "remove trailing comma",
    position: at,
    end_offset: at.offset + 1,
    replacement: "",
  }
}

///|
fn RepairCheckpoint::end_container(
  self : RepairCheckpoint,
  parent : CheckpointContainer,
) -> Bool {
  if parent.phase is AfterComma(at) {
    self.edits.push(checkpoint_removed_comma(at))
    if self.edits.length() > self.max_edits {
      return false
    }
  }
  ignore(self.containers.pop())
  self.output.write_char(if parent.object { '}' } else { ']' })
  self.commit(parent.value(None, false), parent.path)
  true
}

///|
fn RepairCheckpoint::begin_string(
  self : RepairCheckpoint,
  key : Bool,
  path : String,
) -> Unit {
  let lexeme = if key { StringBuilder() } else { self.output }
  lexeme.write_char('"')
  self.token = QuotedToken({
    key,
    path,
    start: self.offset,
    lexeme,
    decoded: StringBuilder(),
    raw_escape: StringBuilder(),
    escape_at: self.position(),
    escape: PlainText,
    raw_high: 0,
  })
}

///|
fn CheckpointString::escaped(self : CheckpointString, unit : Char) -> Bool {
  match self.escape {
    PlainText => {
      self.raw_escape.reset()
      self.escape = EscapeStart
    }
    EscapeStart => {
      let decoded = match unit {
        '"' | '\\' | '/' => unit
        'b' => '\u0008'
        'f' => '\u000C'
        'n' => '\n'
        'r' => '\r'
        't' => '\t'
        'u' => {
          self.escape = HexDigits(0, 0, 0)
          self.raw_escape.write_char(unit)
          return true
        }
        _ => return false
      }
      self.decoded.write_char(decoded)
      self.escape = PlainText
    }
    HexDigits(count, value, high) => {
      let digit = hex_digit(unit)
      if digit < 0 {
        return false
      }
      let value = value * 16 + digit
      if count < 3 {
        self.escape = HexDigits(count + 1, value, high)
      } else if high != 0 {
        if value < 0xDC00 || value > 0xDFFF {
          return false
        }
        let cp = 0x10000 + ((high - 0xD800) << 10) + value - 0xDC00
        self.decoded.write_char(cp.unsafe_to_char())
        self.escape = PlainText
      } else if value < 0xD800 || value > 0xDFFF {
        self.decoded.write_char(value.unsafe_to_char())
        self.escape = PlainText
      } else if value < 0xDC00 {
        self.escape = LowSlash(value)
      } else {
        return false
      }
    }
    LowSlash(high) =>
      if unit == '\\' {
        self.escape = LowU(high)
      } else {
        return false
      }
    LowU(high) =>
      if unit == 'u' {
        self.escape = HexDigits(0, 0, high)
      } else {
        return false
      }
  }
  self.raw_escape.write_char(unit)
  if self.escape is PlainText {
    self.lexeme.write_string(self.raw_escape.to_string())
  }
  true
}

///|
fn RepairCheckpoint::quoted(
  self : RepairCheckpoint,
  quoted : CheckpointString,
  unit : Int32,
) -> Bool {
  if quoted.raw_high != 0 {
    if unit < 0xDC00 || unit > 0xDFFF {
      return false
    }
    let cp = 0x10000 + ((quoted.raw_high - 0xD800) << 10) + unit - 0xDC00
    let scalar = cp.unsafe_to_char()
    quoted.lexeme.write_char(scalar)
    quoted.decoded.write_char(scalar)
    quoted.raw_high = 0
    return true
  }
  if !(quoted.escape is PlainText) || unit == 92 {
    if quoted.escape is PlainText {
      quoted.escape_at = self.position()
    }
    return unit < 128 && quoted.escaped(unit.unsafe_to_char())
  }
  if unit == 34 {
    quoted.lexeme.write_char('"')
    let value = quoted.decoded.to_string()
    self.token = NoToken
    if quoted.key {
      let parent = self.containers.last().unwrap()
      if parent.seen.contains(value) {
        return false
      }
      parent.key = value
      parent.key_json = quoted.lexeme.to_string()
      parent.phase = AfterKey
    } else {
      self.commit(Json::string(value), quoted.path)
    }
    return true
  }
  if unit >= 0xD800 && unit <= 0xDBFF {
    quoted.raw_high = unit
    return true
  }
  if unit < 32 && !quoted.key {
    let at = self.position()
    let letter = unit.unsafe_to_char()
    let replacement = control_escape(letter)
    quoted.lexeme.write_string(replacement)
    quoted.decoded.write_char(letter)
    self.edits.push({
      kind: EscapeControl,
      action: "escape raw control character",
      position: at,
      end_offset: at.offset + 1,
      replacement,
    })
    return self.edits.length() <= self.max_edits
  }
  false
}

///|
fn RepairCheckpoint::start_value(self : RepairCheckpoint, unit : Char) -> Bool {
  if unit is ('{' | '[') {
    if self.containers.length() >= self.max_depth {
      return false
    }
    let path = self.begin_value()
    self.output.write_char(unit)
    self.containers.push({
      object: unit == '{',
      path,
      entries: [],
      seen: Set([]),
      phase: FirstItem,
      key: "",
      key_json: "",
      member_at: self.position(),
    })
  } else if unit == '"' {
    let path = self.begin_value()
    self.begin_string(false, path)
  } else if unit.is_ascii_digit() || unit is ('-' | 't' | 'f' | 'n') {
    let bare = StringBuilder()
    bare.write_char(unit)
    self.token = BareToken(bare)
  } else {
    return false
  }
  true
}

///|
fn RepairCheckpoint::strict_bare(
  self : RepairCheckpoint,
  logical : String,
) -> Json? {
  let cursor = Cursor::new(logical[:], {
    max_input: logical.length(),
    max_depth: self.max_depth,
    max_edits: 0,
  })
  // A fully delimited atom uses the ordinary number/literal lexer and core
  // JSON decoder. No earlier token participates in this validation.
  match cursor.report() {
    Ok(report) if report.json == logical => Some(report.value)
    _ => None
  }
}

///|
fn RepairCheckpoint::outside(self : RepairCheckpoint, unit : Int32) -> Bool {
  // A marker outside a proven JSON string needs the policy parser. Text
  // inside a checkpoint string is protected from reasoning tag recognition.
  if unit > 127 || unit == 60 {
    return false
  }
  let unit = unit.unsafe_to_char()
  if self.token is BareToken(bare) {
    if is_json_space(unit) || unit is (',' | '}' | ']') {
      let logical = bare.to_string()
      guard self.strict_bare(logical) is Some(value) else { return false }
      self.token = NoToken
      let path = self.begin_value()
      self.output.write_string(logical)
      self.commit(value, path)
    } else {
      bare.write_char(unit)
      return true
    }
  }
  if is_json_space(unit) {
    return true
  }
  if self.containers.last() is Some(parent) {
    let closer = if parent.object { '}' } else { ']' }
    match parent.phase {
      FirstItem | AfterComma(_) =>
        if unit == closer {
          self.end_container(parent)
        } else if parent.object {
          if unit != '"' {
            return false
          }
          parent.member_at = match parent.phase {
            AfterComma(at) => at
            _ => self.position()
          }
          self.begin_string(true, "")
          true
        } else {
          self.start_value(unit)
        }
      AfterItem =>
        if unit == ',' {
          parent.phase = AfterComma(self.position())
          true
        } else {
          unit == closer && self.end_container(parent)
        }
      AfterKey =>
        if unit == ':' {
          parent.seen.add(parent.key)
          parent.phase = AfterColon
          true
        } else {
          false
        }
      AfterColon => self.start_value(unit)
    }
  } else {
    self.root is None && self.start_value(unit)
  }
}

///|
fn checkpoint_plain_end(chunk : StringView, start : Int32) -> Int32 {
  let mut end = start
  while end < chunk.length() {
    let unit = chunk[end].to_int()
    if unit < 32 ||
      unit == 34 ||
      unit == 92 ||
      (unit >= 0xD800 && unit <= 0xDFFF) {
      break
    }
    end += 1
  }
  end
}

///|
fn RepairCheckpoint::feed(self : RepairCheckpoint, chunk : StringView) -> Bool {
  let mut index = 0
  while index < chunk.length() {
    let unit = chunk[index].to_int()
    let accepted = if self.token is QuotedToken(quoted) {
      if quoted.escape is PlainText && quoted.raw_high == 0 {
        let end = checkpoint_plain_end(chunk, index)
        if end > index {
          let run = chunk.exact_view(start=index, end~)
          quoted.lexeme.write_view(run)
          quoted.decoded.write_view(run)
          self.offset += end - index
          self.column += end - index
          self.after_cr = false
          index = end
          continue
        }
      }
      self.quoted(quoted, unit)
    } else {
      self.outside(unit)
    }
    if !accepted {
      return false
    }
    self.advance(unit)
    index += 1
  }
  true
}

///|
priv enum CheckpointPatchHint {
  PatchLiveString(Int32, String, String)
  PatchCommittedRoot(Int32)
}

///|
priv struct CheckpointSnapshot {
  report : RepairReport
  fields : Array[FieldSeal]
  hint : CheckpointPatchHint?
}

///|
fn CheckpointString::escape_tail(
  self : CheckpointString,
) -> (String, String, Array[RepairEdit])? {
  let source = "\"" + self.raw_escape.to_string()
  let cursor = Cursor::new(source[:], {
    max_input: source.length(),
    max_depth: 1,
    max_edits: 8,
  })
  match cursor.report() {
    Ok({ json, value: String(decoded), edits, }) => {
      let at = self.escape_at
      // Exclude the temporary wrapper's CloseString. The outer snapshot
      // emits its own source-coordinate close after the escape audit.
      ignore(edits.pop())
      let edits = edits.map(edit => {
        ..edit,
        position: {
          ..at,
          offset: at.offset + edit.position.offset - 1,
          column: at.column + edit.position.column - 2,
        },
        end_offset: at.offset + edit.end_offset - 1,
      })
      Some(
        (json.unsafe_substring(start=1, end=json.length() - 1), decoded, edits),
      )
    }
    _ => None
  }
}

///|
fn RepairCheckpoint::snapshot(
  self : RepairCheckpoint,
  trace : Bool,
) -> CheckpointSnapshot? {
  let suffix = StringBuilder()
  let fields = if trace { self.fields.copy() } else { [] }
  let edits = self.edits.copy()
  let at = self.position()
  let mut hint = None
  let mut active_key = false
  let mut tail = match self.token {
    QuotedToken(quoted) if !quoted.key && quoted.raw_high == 0 => {
      let mut value = quoted.decoded.to_string()
      if quoted.escape is PlainText {
        hint = Some(PatchLiveString(quoted.start, quoted.path, value))
      } else {
        guard quoted.escape_tail() is Some((spelling, decoded, repairs)) else {
          return None
        }
        suffix.write_string(spelling)
        value = value + decoded
        for edit in repairs {
          edits.push(edit)
        }
      }
      suffix.write_char('"')
      edits.push({
        kind: CloseString,
        action: "close truncated string",
        position: at,
        end_offset: at.offset,
        replacement: "\"",
      })
      if trace {
        fields.push({ pointer: quoted.path, is_sealed: false, })
      }
      Some(Json::string(value))
    }
    QuotedToken(quoted) if quoted.key &&
      quoted.escape is PlainText &&
      quoted.raw_high == 0 => {
      active_key = true
      None
    }
    BareToken(bare) => {
      let logical = bare.to_string()
      guard self.strict_bare(logical) is Some(value) else { return None }
      let path = if self.containers.last() is Some(parent) {
        if !parent.entries.is_empty() {
          suffix.write_char(',')
        }
        if parent.object {
          suffix.write_string(parent.key_json)
          suffix.write_char(':')
        }
        pointer_child(parent.path, parent.next_key())
      } else {
        ""
      }
      suffix.write_string(logical)
      if trace {
        fields.push({ pointer: path, is_sealed: false, })
      }
      Some(value)
    }
    NoToken => {
      if self.containers.length() == 1 {
        let root = self.containers[0]
        hint = Some(PatchCommittedRoot(root.entries.length()))
      }
      None
    }
    _ => return None
  }
  for index = self.containers.length() - 1; index >= 0; index = index - 1 {
    let parent = self.containers[index]
    if tail is None {
      if active_key || parent.phase is (AfterKey | AfterColon) {
        edits.push({
          kind: DropIncompleteMember,
          action: "drop final object member without a value",
          position: parent.member_at,
          end_offset: at.offset,
          replacement: "",
        })
      } else if parent.phase is AfterComma(comma) {
        edits.push(checkpoint_removed_comma(comma))
      }
    }
    let closer = if parent.object { "}" } else { "]" }
    suffix.write_string(closer)
    edits.push({
      kind: if parent.object {
        CloseObject
      } else {
        CloseArray
      },
      action: if parent.object {
        "close truncated object"
      } else {
        "close truncated array"
      },
      position: at,
      end_offset: at.offset,
      replacement: closer,
    })
    if trace {
      fields.push({ pointer: parent.path, is_sealed: false, })
    }
    tail = Some(parent.value(tail, true))
  }
  if edits.length() > self.max_edits {
    return None
  }
  let value = match tail {
    Some(value) => value
    None =>
      match self.root {
        Some(value) => clone_patch_value(value)
        None => return None
      }
  }
  let json = self.output.to_string() + suffix.to_string()
  Some({ report: { json, value, edits, }, fields, hint, })
}

///|
fn checkpoint_patches(
  previous : Json,
  previous_hint : CheckpointPatchHint?,
  next : CheckpointSnapshot,
  checkpoint : RepairCheckpoint,
) -> Array[JsonPatch] {
  match (previous_hint, next.hint) {
    (
      Some(PatchLiveString(start, _, before)),
      Some(PatchLiveString(next_start, path, value)),
    ) if start == next_start => {
      // A still-open string has appended decoded units only. Its ancestors
      // and siblings are committed, so diff visits the same single leaf.
      if before.length() == value.length() {
        return []
      }
      return [{ op: "replace", path, value: Some(Json::string(value)), }]
    }
    (Some(PatchCommittedRoot(count)), Some(PatchCommittedRoot(current))) if count <=
      current => {
      let root = checkpoint.containers[0]
      return match next.report.value {
        Object(members) =>
          root.entries[count:current].map(pair => {
            let name = pair.0
            {
              op: "add",
              path: pointer_child("", name),
              value: members.get(name),
            }
          })
        Array(items) =>
          items[count:current].mapi((index, item) => {
            op: "add",
            path: "/\{count + index}",
            value: Some(item),
          })
        _ => diff_json_patches(previous, next.report.value)
      }
    }
    _ => diff_json_patches(previous, next.report.value)
  }
}
