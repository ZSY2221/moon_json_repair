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
/// Classification of an edit applied to the source. Use
/// `RepairEdit::code` for the most specific serialized code.
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
/// Return the stable snake-case code for this edit category.
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
/// Serialize the operation and its original UTF-16 span. Use an empty
/// replacement to represent removal.
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
/// A successful repair with compact JSON text, its parsed value, and edits.
/// Use `json` as the wire representation when an ordinary host
/// JSON parser would lose large integers or decimal spellings.
#derive(Eq, Debug)
pub(all) struct RepairReport {
  json : String
  value : JsonValue
  edits : Array[RepairEdit]
}

///|
/// Serialize both the exact JSON text and its parsed value, along with the
/// ordered source audit.
pub impl ToJson for RepairReport with fn to_json(self) {
  { "json": self.json, "value": self.value, "edits": @json.to_json(self.edits) }
}

///|
/// Why one document was rejected. A limit error indicates the corresponding
/// input, nesting, or edit budget was exhausted.
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
/// Return the stable snake-case code for programmatic failure handling.
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
/// A rejected repair with a machine-readable category, a human-readable
/// message, and the original source position associated with the failure.
#derive(Eq, Debug)
pub(all) struct RepairError {
  kind : RepairFailureKind
  message : String
  position : SourcePosition
}

///|
/// Serialize the failure using its stable category code and original
/// UTF-16 position.
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
/// Allow 1,048,576 UTF-16 units, 128 container levels, and 16,384 edits.
pub fn RepairLimits::default() -> RepairLimits {
  { max_input: 1_048_576, max_depth: 128, max_edits: 16_384, }
}

///|
/// Single-document repair and extraction options. Set json5 to accept exact
/// hexadecimal integers and extended decimal spellings. max_blocks limits
/// successful extraction results and is clamped to 0–4,096.
#derive(Eq, Debug)
pub(all) struct RepairOptions {
  limits : RepairLimits
  json5 : Bool
  max_blocks : Int32
}

///|
/// Use the default repair limits, disable JSON5 numbers, and allow extraction
/// to return up to 128 independent documents.
pub fn RepairOptions::default() -> RepairOptions {
  { limits: RepairLimits::default(), json5: false, max_blocks: 128, }
}

///|
/// Repair options plus optional isolation of case-insensitive think tags.
/// Batch repair, extraction, and streams share the policy.
#derive(Eq, Debug)
pub(all) struct RepairPolicy {
  options : RepairOptions
  ignore_think_blocks : Bool
}

///|
/// Use default `RepairOptions` and treat reasoning tags as ordinary input.
pub fn RepairPolicy::default() -> RepairPolicy {
  { options: RepairOptions::default(), ignore_think_blocks: false, }
}

///|
/// Set reasoning isolation while preserving the current repair limits,
/// numeric options, and extraction budget.
pub fn RepairOptions::with_ignore_think_blocks(
  self : RepairOptions,
  ignore_think_blocks : Bool,
) -> RepairPolicy {
  { options: self, ignore_think_blocks, }
}
