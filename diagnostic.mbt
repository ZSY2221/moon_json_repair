///|
/// A source diagnostic from repair, its audit trail, or schema validation.
pub(all) enum SourceDiagnostic {
  Repair(RepairError)
  Edit(RepairEdit)
  Schema(ValidationError)
}

///|
priv struct DiagnosticRange {
  start : Int32
  finish : Int32
}

///|
priv struct DiagnosticEntry {
  code : String
  message : String
  suggestion : String
  range : DiagnosticRange
  path : String?
  is_edit : Bool
}

///|
fn diagnostic_escape(unit : Int32) -> String {
  let digits = "0123456789abcdef"
  let output = StringBuilder()
  output.write_string("\\u")
  for shift in [12, 8, 4, 0] {
    output.write_char(digits[(unit >> shift) & 15].to_int().unsafe_to_char())
  }
  output.to_string()
}

///|
fn diagnostic_high(unit : Int32) -> Bool {
  unit >= 0xD800 && unit <= 0xDBFF
}

///|
fn diagnostic_low(unit : Int32) -> Bool {
  unit >= 0xDC00 && unit <= 0xDFFF
}

///|
fn diagnostic_control(unit : Int32) -> Bool {
  unit < 0x20 ||
  (unit >= 0x7F && unit <= 0x9F) ||
  unit == 0x061C ||
  unit == 0x200E ||
  unit == 0x200F ||
  (unit >= 0x2028 && unit <= 0x202E) ||
  (unit >= 0x2066 && unit <= 0x2069) ||
  unit == 0xFEFF
}

///|
fn diagnostic_width(unit : Int32) -> Int32 {
  match unit {
    0x0300..<=0x036F
    | 0x1AB0..<=0x1AFF
    | 0x1DC0..<=0x1DFF
    | 0x200D
    | 0x20D0..<=0x20FF
    | 0xFE00..<=0xFE0F
    | 0xFE20..<=0xFE2F
    | 0x1F3FB..<=0x1F3FF => 0
    0x1100..<=0x115F
    | 0x2329..<=0x232A
    | 0x2E80..<=0xA4CF
    | 0xAC00..<=0xD7A3
    | 0xF900..<=0xFAFF
    | 0xFE10..<=0xFE19
    | 0xFE30..<=0xFE6F
    | 0xFF00..<=0xFF60
    | 0xFFE0..<=0xFFE6
    | 0x1F000..<=0x1FAFF
    | 0x20000..<=0x3FFFD => 2
    _ => 1
  }
}

///|
fn diagnostic_scalar(
  source : String,
  offset : Int32,
  end : Int32,
) -> (Int32, Int32) {
  let lead = source[offset].to_int()
  if diagnostic_high(lead) &&
    offset + 1 < end &&
    diagnostic_low(source[offset + 1].to_int()) {
    let tail = source[offset + 1].to_int()
    (0x10000 + ((lead - 0xD800) << 10) + tail - 0xDC00, 2)
  } else {
    (lead, 1)
  }
}

///|
fn diagnostic_regional_indicator(unit : Int32) -> Bool {
  unit >= 0x1F1E6 && unit <= 0x1F1FF
}

///|
fn diagnostic_emoji(unit : Int32) -> Bool {
  unit is (0x1F000..<=0x1FAFF | 0x2300..<=0x23FF | 0x2600..<=0x27BF)
}

///|
fn diagnostic_unicode_cell(
  source : String,
  offset : Int32,
  end : Int32,
  lead : Int32,
  units : Int32,
) -> (String, Int32, Int32) {
  let mut finish = offset + units
  let mut width = diagnostic_width(lead)
  let mut flag_start = diagnostic_regional_indicator(lead)
  let emoji = diagnostic_emoji(lead)
  while finish < end {
    let (next, size) = diagnostic_scalar(source, finish, end)
    if flag_start && diagnostic_regional_indicator(next) {
      finish += size
      flag_start = false
    } else if next == 0x200D {
      if !emoji || finish + size == end {
        break
      }
      let (joined, joined_size) = diagnostic_scalar(source, finish + size, end)
      if !diagnostic_emoji(joined) {
        break
      }
      finish += size + joined_size
      width = 2
    } else if diagnostic_width(next) == 0 {
      if (next == 0xFE0F && emoji) || next == 0x20E3 {
        width = width.max(2)
      }
      finish += size
    } else {
      break
    }
  }
  // finish can precede a standalone low surrogate in malformed source.
  // The displayed span itself contains only scalars selected above.
  (
    source.unsafe_view(start=offset, end=finish).to_owned(),
    finish - offset,
    width,
  )
}

///|
fn diagnostic_cell(
  source : String,
  offset : Int32,
  end : Int32,
  column : Int32,
) -> (String, Int32, Int32) {
  let (lead, units) = diagnostic_scalar(source, offset, end)
  if lead == 9 {
    let spaces = 4 - column % 4
    (" ".repeat(spaces), 1, spaces)
  } else if diagnostic_control(lead) ||
    diagnostic_high(lead) ||
    diagnostic_low(lead) {
    (diagnostic_escape(lead), 1, 6)
  } else {
    diagnostic_unicode_cell(source, offset, end, lead, units)
  }
}

///|
fn diagnostic_safe_text(text : String) -> String {
  let rendered = StringBuilder()
  let limit = text.length().min(320)
  let mut offset = 0
  let mut column = 0
  while offset < limit {
    let (cell, units, width) = diagnostic_cell(text, offset, limit, column)
    rendered.write_string(cell)
    offset += units
    column += width
  }
  if limit < text.length() {
    rendered.write_char('…')
  }
  rendered.to_string()
}

///|
fn diagnostic_source_lines(source : String) -> Array[DiagnosticRange] {
  let lines = []
  let mut start = 0
  let mut offset = 0
  while offset < source.length() {
    let unit = source[offset].to_int()
    if unit == 13 || unit == 10 {
      lines.push({ start, finish: offset, })
      offset += if unit == 13 &&
        offset + 1 < source.length() &&
        source[offset + 1].to_int() == 10 {
        2
      } else {
        1
      }
      start = offset
    } else {
      offset += 1
    }
  }
  lines.push({ start, finish: source.length(), })
  lines
}

///|
fn diagnostic_line_at(lines : Array[DiagnosticRange], offset : Int32) -> Int32 {
  let mut low = 0
  let mut high = lines.length()
  while low + 1 < high {
    let middle = low + (high - low) / 2
    if lines[middle].start <= offset {
      low = middle
    } else {
      high = middle
    }
  }
  if offset > lines[low].finish && high < lines.length() {
    high
  } else {
    low
  }
}

///|
fn diagnostic_window(
  source : String,
  range : DiagnosticRange,
  offset : Int32,
) -> DiagnosticRange {
  let mut start = (offset - 36).max(range.start)
  let mut finish = (start + 96).min(range.finish)
  if start > range.start &&
    diagnostic_low(source[start].to_int()) &&
    diagnostic_high(source[start - 1].to_int()) {
    start -= 1
  }
  if finish < range.finish &&
    diagnostic_low(source[finish].to_int()) &&
    diagnostic_high(source[finish - 1].to_int()) {
    finish += 1
  }
  { start, finish, }
}

///|
fn diagnostic_write_window(
  output : StringBuilder,
  source : String,
  row : DiagnosticRange,
  window : DiagnosticRange,
  marker : DiagnosticRange,
) -> (Int32, Int32) {
  let left_clipped = window.start > row.start
  let mut column = if left_clipped { 1 } else { 0 }
  let mut marker_start = column
  let mut marker_width = 0
  if left_clipped {
    output.write_char('…')
  }
  let mut offset = window.start
  while offset < window.finish {
    let (cell, units, width) = diagnostic_cell(
      source,
      offset,
      window.finish,
      column,
    )
    output.write_string(cell)
    if offset + units <= marker.start {
      marker_start += width
    } else if offset < marker.finish {
      marker_width += width
    }
    offset += units
    column += width
  }
  if window.finish < row.finish {
    output.write_char('…')
  }
  output.write_char('\n')
  (marker_start, marker_width.max(1))
}

///|
fn diagnostic_repair_words(
  error : RepairError,
  chinese : Bool,
) -> (String, String) {
  if chinese {
    match error.kind {
      EmptyInput => ("输入为空", "提供一个 JSON 值后重试。")
      UnexpectedToken =>
        (
          "遇到无法识别的 JSON 标记", "检查标注处的值、引号或分隔符。",
        )
      InvalidUnicode =>
        (
          "Unicode 字符或转义无效", "使用有效的 Unicode 标量或配对的代理项。",
        )
      InvalidNumber =>
        (
          "数字格式无效", "使用合法的 JSON 十进制写法，保留原整数精度。",
        )
      DuplicateKey =>
        (
          "对象键重复", "删除重复键，或为不同字段取不同名称。",
        )
      TrailingContent =>
        (
          "文档后还有其他内容", "每次传入一个 JSON 值，或分别提取多个值。",
        )
      DepthLimit =>
        ("超过最大嵌套深度", "减少容器层数后重试。")
      InputLimit =>
        (
          "超过输入长度预算", "缩小输入，或拆分为独立文档。",
        )
      EditLimit =>
        (
          "超过修复编辑预算", "先修正源文本中的重复格式问题。",
        )
    }
  } else {
    let suggestion = match error.kind {
      EmptyInput => "Provide one JSON value."
      UnexpectedToken => "Check the marked value, quote, or separator."
      InvalidUnicode => "Use a Unicode scalar or a matched surrogate pair."
      InvalidNumber =>
        "Use valid JSON decimal syntax and preserve integer digits."
      DuplicateKey =>
        "Remove the duplicate key or give the fields distinct names."
      TrailingContent => "Pass one JSON value or extract the blocks separately."
      DepthLimit => "Reduce the number of nested containers."
      InputLimit => "Shorten the input or split it into independent documents."
      EditLimit => "Correct recurring formatting problems at the source."
    }
    (error.message, suggestion)
  }
}

///|
fn diagnostic_edit_words(edit : RepairEdit, chinese : Bool) -> String {
  if !chinese {
    return edit.action
  }
  match edit.kind {
    StripProse if edit.code() == "ignore_think_block" => "隔离推理草稿"
    StripProse => "移除 JSON 外的说明文字"
    StripFence => "移除代码围栏"
    StripBom => "移除字节顺序标记"
    RemoveComment => "移除注释"
    RemoveTrailingComma => "移除尾随逗号"
    InsertComma => "补上分隔逗号"
    QuoteKey => "为对象键加引号"
    NormalizeQuote => "规范字符串引号"
    EscapeControl => "转义控制字符"
    EscapeBackslash => "转义反斜杠"
    NormalizeLiteral => "规范字面量"
    CompleteLiteral => "补全字面量"
    CloseString => "闭合字符串"
    CloseArray => "闭合数组"
    CloseObject => "闭合对象"
    DropIncompleteMember => "去掉未完成的对象成员"
  }
}

///|
fn diagnostic_schema_words(
  error : ValidationError,
  chinese : Bool,
) -> (String, String) {
  if chinese {
    let description = match error.keyword {
      "type" => "值的类型与定义不符"
      "required" => "缺少必填字段"
      "enum" => "值不在允许的枚举列表中"
      "minimum" => "数值低于最小值"
      "maximum" => "数值超过最大值"
      "minLength" => "文本短于最小长度"
      "maxLength" => "文本超过最大长度"
      "additionalProperties" => "对象包含未定义的键"
      "depth" => "超过校验嵌套深度"
      "ambiguous_key" => "键名可匹配多个属性"
      "key_collision" => "迁移键名会与现有属性冲突"
      _ => "未满足约束条件"
    }
    if error.path.has_prefix("$schema") {
      ("约束定义无效", "修正该路径上的约束定义后重试。")
    } else {
      (description, "按约束要求检查该路径，然后重新提交。")
    }
  } else if error.path.has_prefix("$schema") {
    (error.message, "Correct this rule in the schema definition.")
  } else {
    (error.message, "Correct the marked value to satisfy this rule and retry.")
  }
}

///|
fn diagnostic_instance_path(path : String) -> String {
  if path.has_prefix("$schema") {
    "$\{path[7:].to_owned()}"
  } else {
    path
  }
}

///|
fn diagnostic_path_starts(path : String) -> Array[Int32] {
  let starts = []
  let mut quoted = false
  let mut escaped = false
  for offset in 1..<path.length() {
    let unit = path[offset].to_int()
    if quoted {
      if escaped {
        escaped = false
      } else if unit == 92 {
        escaped = true
      } else if unit == 34 {
        quoted = false
      }
    } else if unit == 34 {
      quoted = true
    } else if unit == 46 || unit == 91 {
      starts.push(offset)
    }
  }
  starts
}

///|
priv struct DiagnosticWalker {
  source : String
  paths : Map[String, DiagnosticRange?]
  mut offset : Int32
}

///|
fn DiagnosticWalker::peek(self : DiagnosticWalker) -> Int32 {
  if self.offset < self.source.length() {
    self.source[self.offset].to_int()
  } else {
    -1
  }
}

///|
fn DiagnosticWalker::skip_space(self : DiagnosticWalker) -> Unit {
  while self.peek() is (9 | 10 | 13 | 32) {
    self.offset += 1
  }
}

///|
fn DiagnosticWalker::take(self : DiagnosticWalker, expected : Int32) -> Bool {
  if self.peek() == expected {
    self.offset += 1
    true
  } else {
    false
  }
}

///|
fn DiagnosticWalker::string_end(self : DiagnosticWalker) -> Bool {
  if !self.take(34) {
    return false
  }
  while self.offset < self.source.length() {
    let unit = self.peek()
    self.offset += 1
    if unit == 34 {
      return true
    } else if unit == 92 {
      self.offset += 1
    }
  }
  false
}

///|
fn DiagnosticWalker::tracked(self : DiagnosticWalker, path : String) -> String? {
  if self.paths.contains(path) {
    Some(path)
  } else {
    None
  }
}

///|
fn DiagnosticWalker::object_children(
  self : DiagnosticWalker,
  path : String?,
  depth : Int32,
) -> Bool {
  self.skip_space()
  if self.take(125) {
    return true
  }
  while true {
    self.skip_space()
    let key_start = self.offset
    if !self.string_end() {
      return false
    }
    let child = match path {
      Some(parent) =>
        try
          @json.parse(self.source.unsafe_view(start=key_start, end=self.offset))
        catch {
          _ => return false
        } noraise {
          String(name) => self.tracked(schema_key_path(parent, name))
          _ => return false
        }
      None => None
    }
    self.skip_space()
    if !self.take(58) || !self.walk(child, depth) {
      return false
    }
    self.skip_space()
    if self.take(125) {
      return true
    }
    if !self.take(44) {
      return false
    }
  }
  true
}

///|
fn DiagnosticWalker::array_children(
  self : DiagnosticWalker,
  path : String?,
  depth : Int32,
) -> Bool {
  self.skip_space()
  if self.take(93) {
    return true
  }
  for index = 0 {
    let child = path.bind(parent => self.tracked("\{parent}[\{index}]"))
    if !self.walk(child, depth) {
      break false
    }
    self.skip_space()
    if self.take(93) {
      break true
    }
    if !self.take(44) {
      break false
    }
    continue index + 1
  }
}

///|
fn DiagnosticWalker::walk(
  self : DiagnosticWalker,
  path : String?,
  depth : Int32,
) -> Bool {
  self.skip_space()
  let start = self.offset
  if depth > schema_depth_limit + 2 {
    return false
  }
  let valid = match self.peek() {
    123 => {
      self.offset += 1
      self.object_children(path, depth + 1)
    }
    91 => {
      self.offset += 1
      self.array_children(path, depth + 1)
    }
    34 => self.string_end()
    _ => {
      while !(self.peek() is (-1 | 9 | 10 | 13 | 32 | 44 | 93 | 125)) {
        self.offset += 1
      }
      self.offset > start
    }
  }
  if valid && path is Some(path) {
    self.paths[path] = Some({ start, finish: self.offset, })
  }
  valid
}

///|
fn diagnostic_schema_ranges(
  source : String,
  diagnostics : Array[SourceDiagnostic],
) -> Map[String, DiagnosticRange?] {
  let paths = Map([])
  for diagnostic in diagnostics {
    if diagnostic is Schema(error) {
      let path = diagnostic_instance_path(error.path)
      paths[path] = None
      for start in diagnostic_path_starts(path) {
        paths[path[:start].to_owned()] = None
      }
    }
  }
  if !paths.is_empty() {
    let walker = { source, paths, offset: 0, }
    if !walker.walk(Some("$"), 0) {
      return Map([])
    }
    walker.skip_space()
    if walker.offset != source.length() {
      return Map([])
    }
  }
  paths
}

///|
fn diagnostic_lookup(
  paths : Map[String, DiagnosticRange?],
  path : String,
) -> DiagnosticRange {
  let path = diagnostic_instance_path(path)
  if paths.get(path) is Some(Some(range)) {
    return range
  }
  let starts = diagnostic_path_starts(path)
  for index = starts.length() - 1; index >= 0; index = index - 1 {
    if paths.get(path[:starts[index]].to_owned()) is Some(Some(range)) {
      return range
    }
  }
  { start: 0, finish: 0, }
}

///|
fn diagnostic_entry(
  diagnostic : SourceDiagnostic,
  paths : Map[String, DiagnosticRange?],
  chinese : Bool,
) -> DiagnosticEntry {
  match diagnostic {
    Repair(error) => {
      let (message, suggestion) = diagnostic_repair_words(error, chinese)
      {
        code: error.kind.code(),
        message,
        suggestion,
        range: { start: error.position.offset, finish: error.position.offset, },
        path: None,
        is_edit: false,
      }
    }
    Edit(edit) => {
      let suggestion = if edit.replacement.is_empty() {
        if chinese {
          "空替换表示移除原片段。"
        } else {
          "An empty replacement removes the marked span."
        }
      } else if chinese {
        "替换为 \{edit.replacement}"
      } else {
        "Replace with \{edit.replacement}"
      }
      {
        code: edit.code(),
        message: diagnostic_edit_words(edit, chinese),
        suggestion,
        range: { start: edit.position.offset, finish: edit.end_offset, },
        path: None,
        is_edit: true,
      }
    }
    Schema(error) => {
      let (message, suggestion) = diagnostic_schema_words(error, chinese)
      {
        code: error.keyword,
        message,
        suggestion,
        range: diagnostic_lookup(paths, error.path),
        path: Some(error.path),
        is_edit: false,
      }
    }
  }
}

///|
fn diagnostic_write_entry(
  output : StringBuilder,
  source : String,
  lines : Array[DiagnosticRange],
  entry : DiagnosticEntry,
  ansi : Bool,
  chinese : Bool,
) -> Unit {
  let offset = entry.range.start.clamp(min=0, max=source.length())
  let line = diagnostic_line_at(lines, offset)
  let column = (offset - lines[line].start).max(0) + 1
  let first = (line - 1).max(0)
  let last = (line + 1).min(lines.length() - 1)
  let digits = (last + 1).to_string().length()
  let gutter = " ".repeat(digits)
  let color = if !ansi {
    ""
  } else if entry.is_edit {
    "\u001b[1;36m"
  } else {
    "\u001b[1;31m"
  }
  let reset = if ansi { "\u001b[0m" } else { "" }
  let heading = if chinese {
    if entry.is_edit {
      "编辑"
    } else {
      "错误"
    }
  } else if entry.is_edit {
    "edit"
  } else {
    "error"
  }
  let divider = if chinese { "：" } else { ": " }
  let help = if chinese { "建议：" } else { "help: " }
  let mark = { start: offset, finish: entry.range.finish.max(offset), }
  output.write_string(
    "\{color}\{heading}[\{diagnostic_safe_text(entry.code)}]\{reset}\{divider}\{diagnostic_safe_text(entry.message)}\n",
  )
  output.write_string("\{gutter} --> \{line + 1}:\{column} (UTF-16)")
  if entry.path is Some(path) {
    output.write_string(" \{diagnostic_safe_text(path)}")
  }
  output.write_string("\n\{gutter} |\n")
  for index in first..<=last {
    let row = lines[index]
    let number = (index + 1).to_string()
    let indent = " ".repeat(digits - number.length())
    output.write_string("\{indent}\{number} | ")
    let active = index == line
    let anchor = if active {
      offset.clamp(min=row.start, max=row.finish)
    } else {
      row.start
    }
    let window = diagnostic_window(source, row, anchor)
    let (start, length) = diagnostic_write_window(
      output, source, row, window, mark,
    )
    if active {
      output.write_string(
        "\{gutter} | \{" ".repeat(start)}\{color}\{"^".repeat(length)}\{reset}\n",
      )
    }
  }
  output.write_string(
    "\{gutter} = \{help}\{diagnostic_safe_text(entry.suggestion)}\n",
  )
}

///|
/// Render diagnostics with one context line on either side and a bounded
/// horizontal source window. Repair positions refer to the original text.
/// Use exact strict JSON for instance schema diagnostics and the schema
/// document for definition diagnostics. Missing values anchor to the nearest
/// containing value. Location numbers use one-based UTF-16 columns while
/// the caret uses display cells. Unsafe terminal controls are escaped.
pub fn render_diagnostics(
  source : String,
  diagnostics : Array[SourceDiagnostic],
  ansi~ : Bool = false,
  chinese~ : Bool = false,
) -> String {
  if diagnostics.is_empty() {
    return ""
  }
  let lines = diagnostic_source_lines(source)
  let paths = diagnostic_schema_ranges(source, diagnostics)
  let output = StringBuilder()
  for index, diagnostic in diagnostics {
    if index > 0 {
      output.write_char('\n')
    }
    diagnostic_write_entry(
      output,
      source,
      lines,
      diagnostic_entry(diagnostic, paths, chinese),
      ansi,
      chinese,
    )
  }
  output.to_string()
}

///|
/// Render a source diagnostic as plain text, optionally with ANSI color and
/// Simplified Chinese headings and guidance.
pub fn render_diagnostic(
  source : String,
  diagnostic : SourceDiagnostic,
  ansi~ : Bool = false,
  chinese~ : Bool = false,
) -> String {
  render_diagnostics(source, [diagnostic], ansi~, chinese~)
}

///|
/// Summarize the audit and render previews of the first eight edits, in
/// discovery order. The structured audit retains every original edit.
pub fn render_repair_audit(
  source : String,
  edits : Array[RepairEdit],
  ansi~ : Bool = false,
  chinese~ : Bool = false,
) -> String {
  let shown = edits.length().min(8)
  let summary = if chinese {
    "修复审计：\{edits.length()} 项编辑"
  } else {
    "Repair audit: \{edits.length()} edits"
  }
  let tail = if shown == edits.length() {
    ""
  } else if chinese {
    "\n另有 \{edits.length() - shown} 项，详见结构化审计。\n"
  } else {
    "\n\{edits.length() - shown} more in the structured audit.\n"
  }
  let diagnostics = []
  for index in 0..<shown {
    diagnostics.push(Edit(edits[index]))
  }
  "\{summary}\n\{render_diagnostics(source, diagnostics, ansi~, chinese~)}\{tail}"
}
