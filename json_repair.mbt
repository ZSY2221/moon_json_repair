///|
/// The standard-library JSON AST. Numbers retain their original decimal
/// spelling in the Number constructor's repr field.
pub type JsonValue = Json

///|
/// Offsets are zero-based. Lines and columns start at one. Offsets and
/// columns count UTF-16 code units in the original input.
#derive(Eq, Debug, ToJson)
pub(all) struct SourcePosition {
  offset : Int32
  line : Int32
  column : Int32
}

///|
#derive(Eq, Debug)
pub(all) enum RepairKind {
  StripProse
  StripFence
  StripBom
  RemoveComment
  RemoveTrailingComma
  InsertComma
  QuoteKey
  NormalizeQuote
  EscapeControl
  EscapeBackslash
  NormalizeLiteral
  CompleteLiteral
  CloseString
  CloseArray
  CloseObject
  DropIncompleteMember
}

///|
pub fn RepairKind::code(self : RepairKind) -> String {
  match self {
    StripProse => "strip_prose"
    StripFence => "strip_fence"
    StripBom => "strip_bom"
    RemoveComment => "remove_comment"
    RemoveTrailingComma => "remove_trailing_comma"
    InsertComma => "insert_comma"
    QuoteKey => "quote_key"
    NormalizeQuote => "normalize_quote"
    EscapeControl => "escape_control"
    EscapeBackslash => "escape_backslash"
    NormalizeLiteral => "normalize_literal"
    CompleteLiteral => "complete_literal"
    CloseString => "close_string"
    CloseArray => "close_array"
    CloseObject => "close_object"
    DropIncompleteMember => "drop_incomplete_member"
  }
}

///|
/// An edit in discovery order. The exclusive end offset equals the start
/// offset for insertions. Formatting whitespace is outside the audit.
#derive(Eq, Debug)
pub(all) struct RepairEdit {
  kind : RepairKind
  action : String
  position : SourcePosition
  end_offset : Int32
  replacement : String
}

///|
/// More specific serialized identity for optional repairs. The original
/// RepairKind remains exhaustive for source-compatible consumers.
pub fn RepairEdit::code(self : RepairEdit) -> String {
  match (self.kind, self.action) {
    (NormalizeLiteral, "convert hexadecimal integer to decimal") =>
      "hex_int_to_decimal"
    (NormalizeLiteral, "normalize JSON5 decimal number") => "normalize_decimal"
    (StripProse, "ignore think block" | "ignore unterminated think block") =>
      "ignore_think_block"
    _ => self.kind.code()
  }
}

///|
pub impl ToJson for RepairEdit with fn to_json(self) {
  {
    "kind": self.code(),
    "action": self.action,
    "position": @json.to_json(self.position),
    "end_offset": self.end_offset,
    "replacement": self.replacement,
  }
}

///|
#derive(Eq, Debug)
pub(all) struct RepairReport {
  json : String
  value : JsonValue
  edits : Array[RepairEdit]
}

///|
pub impl ToJson for RepairReport with fn to_json(self) {
  { "json": self.json, "value": self.value, "edits": @json.to_json(self.edits) }
}

///|
#derive(Eq, Debug)
pub(all) enum RepairFailureKind {
  EmptyInput
  UnexpectedToken
  InvalidUnicode
  InvalidNumber
  DuplicateKey
  TrailingContent
  DepthLimit
  InputLimit
  EditLimit
}

///|
pub fn RepairFailureKind::code(self : RepairFailureKind) -> String {
  match self {
    EmptyInput => "empty_input"
    UnexpectedToken => "unexpected_token"
    InvalidUnicode => "invalid_unicode"
    InvalidNumber => "invalid_number"
    DuplicateKey => "duplicate_key"
    TrailingContent => "trailing_content"
    DepthLimit => "depth_limit"
    InputLimit => "input_limit"
    EditLimit => "edit_limit"
  }
}

///|
#derive(Eq, Debug)
pub(all) struct RepairError {
  kind : RepairFailureKind
  message : String
  position : SourcePosition
}

///|
pub impl ToJson for RepairError with fn to_json(self) {
  {
    "kind": self.kind.code(),
    "message": self.message,
    "position": @json.to_json(self.position),
  }
}

///|
/// Nesting is clamped to 1–256. The other limits are clamped at zero.
/// Input size is measured in UTF-16 code units.
#derive(Eq, Debug)
pub(all) struct RepairLimits {
  max_input : Int32
  max_depth : Int32
  max_edits : Int32
}

///|
pub fn RepairLimits::default() -> RepairLimits {
  { max_input: 1_048_576, max_depth: 128, max_edits: 16_384, }
}

///|
/// Extra repair behavior is explicitly enabled. Extraction considers at most
/// max_blocks successful candidates, clamped to the inclusive range 0–4096.
/// Start with RepairOptions::default and update only the options you need.
#derive(Eq, Debug)
pub(all) struct RepairOptions {
  limits : RepairLimits
  json5 : Bool
  max_blocks : Int32
}

///|
pub fn RepairOptions::default() -> RepairOptions {
  { limits: RepairLimits::default(), json5: false, max_blocks: 128, }
}

///|
/// Protocol handling for a model reply. Wrap the existing RepairOptions so
/// exhaustive literals and function references from earlier releases still
/// work. Reasoning isolation is opt-in.
#derive(Eq, Debug)
pub(all) struct RepairPolicy {
  options : RepairOptions
  ignore_think_blocks : Bool
}

///|
pub fn RepairPolicy::default() -> RepairPolicy {
  { options: RepairOptions::default(), ignore_think_blocks: false, }
}

///|
pub fn RepairOptions::with_ignore_think_blocks(
  self : RepairOptions,
  ignore_think_blocks : Bool,
) -> RepairPolicy {
  { options: self, ignore_think_blocks, }
}
