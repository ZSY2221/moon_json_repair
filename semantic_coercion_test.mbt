///|
fn semantic(value : Json, schema : Json) -> @json_repair.CoercionReport {
  @json_repair.coerce_with_schema_semantic(value, schema)
}

///|
fn expect_key(source : String, target : String) -> Unit raise {
  let fields : Map[String, Json] = Map([(source, Json::string("value"))])
  let rules : Map[String, Json] = Map([(target, { "type": "string" })])
  let report = semantic(Json::object(fields), {
    "required": [target],
    "properties": Json::object(rules),
  })
  assert_true(report.errors.is_empty())
  assert_eq(report.value, Json::object(Map([(target, Json::string("value"))])))
  guard report.edits is [edit] else { fail("expected one key edit") }
  assert_eq(edit.path, "$." + target)
  assert_eq(edit.kind, "rename_key")
  assert_eq(edit.before, Json::string(source))
  assert_eq(edit.after, Json::string(target))
  assert_true(fields.contains(source))
}

///|
test "semantic is additive to the old explicit CoercionOptions record" {
  let options : @json_repair.CoercionOptions = {
    number_strings: true,
    boolean_strings: true,
    wrap_scalar_arrays: false,
  }
  let value : Json = { "userName": 1, "currency": "usd" }
  let schema : Json = {
    "required": ["user_name"],
    "properties": {
      "user_name": { "type": "integer" },
      "currency": { "enum": ["USD"] },
    },
  }
  let legacy = @json_repair.coerce_with_schema(value, schema, options~)
  assert_eq(legacy.value, value)
  assert_true(legacy.edits.is_empty())
  assert_eq(legacy.errors.map(e => e.keyword), ["required", "enum"])
  let recovery = semantic(value, schema)
  assert_true(recovery.errors.is_empty())
  assert_eq(recovery.value, { "user_name": 1, "currency": "USD" })
}

///|
test "semantic normalizes camel case to a snake case property" {
  expect_key("userName", "user_name")
}

///|
test "semantic normalizes uppercase and surrounding underscores" {
  expect_key("__USERID_", "user_id")
}

///|
test "semantic normalizes snake case to a camel case property" {
  expect_key("session_id", "sessionId")
}

///|
test "semantic recovers a short one-character substitution" {
  expect_key("idx", "idy")
}

///|
test "semantic recovers a single missing key character" {
  expect_key("amout", "amount")
}

///|
test "semantic recovers a single extra key character" {
  expect_key("amounnt", "amount")
}

///|
test "semantic recovers two substitutions for long identifiers" {
  expect_key("prodxctCoze", "productCode")
}

///|
test "semantic recovers two insertions for long identifiers" {
  expect_key("productXCodeY", "productCode")
}

///|
test "semantic recovers two deletions for long identifiers" {
  expect_key("prodctode", "productCode")
}

///|
test "semantic refuses to fix two changes in a short key" {
  let input : Json = { "xide": 1 }
  let result = semantic(input, {
    "required": ["sidea"],
    "properties": { "sidea": true },
  })
  assert_eq(result.value, input)
  assert_true(result.edits.is_empty())
  assert_eq(result.errors[0].keyword, "required")
}

///|
test "semantic refuses to fix three changes in a long key" {
  let input : Json = { "prxdxctCxde": 1 }
  let result = semantic(input, {
    "required": ["productCode"],
    "properties": { "productCode": true },
  })
  assert_eq(result.value, input)
  assert_true(result.edits.is_empty())
  assert_eq(result.errors[0].keyword, "required")
}

///|
test "semantic exact aliases outrank typo candidates without errors" {
  let report = semantic({ "userName": "Ada" }, {
    "properties": { "user_names": true, "user_name": true },
  })
  assert_true(report.errors.is_empty())
  assert_eq(report.edits.map(e => e.path), ["$.user_name"])
}

///|
test "semantic lower-distance wins despite a farther declared key" {
  let report = semantic({ "itemCounter": "2" }, {
    "properties": {
      "item_marker": { "type": "integer" },
      "item_count": { "type": "integer" },
      "item_counters": { "type": "integer" },
    },
  })
  assert_true(report.errors.is_empty())
  assert_eq(report.edits.map(e => e.path), [
    "$.item_counters", "$.item_counters",
  ])
}

///|
test "semantic does not alter a field whose spelling already exists" {
  let result = semantic({ "id": "9" }, {
    "properties": { "id": true, "it": true },
  })
  assert_true(result.errors.is_empty())
  assert_true(result.edits.is_empty())
}

///|
test "semantic tie between two distant neighbors generates a retry even for optional properties" {
  let value : Json = { "hat": 5 }
  let schema : Json = { "properties": { "cat": true, "bat": true } }
  let result = semantic(value, schema)
  assert_eq(result.value, value)
  assert_true(result.edits.is_empty())
  guard result.errors is [error] else { fail("expected one semantic error") }
  assert_eq(error.keyword, "ambiguous_key")
  assert_eq(error.path, "$.hat")
  assert_true(@json_repair.format_retry_prompt(value, schema).is_empty())
  assert_true(result.format_retry_prompt(schema).contains("\"path\":\"$.hat\""))
  assert_true(result.format_retry_prompt(schema).contains("bat and cat"))
}

///|
test "semantic retry lists a deterministic pair for three equal candidates" {
  let schema : Json = {
    "properties": { "sat": true, "cat": true, "bat": true },
  }
  let result = semantic({ "hat": 5 }, schema)
  assert_true(result.format_retry_prompt(schema).contains("bat and cat"))
  assert_eq(result.errors[0].keyword, "ambiguous_key")
}

///|
test "semantic ties reserve all equally close targets and allow unrelated migrations" {
  let schema : Json = {
    "properties": { "bat": true, "cat": true, "sat": true, "user_name": true },
  }
  let result = semantic({ "hat": 5, "satt": 7, "userName": "Ada" }, schema)
  assert_eq(result.value, { "hat": 5, "satt": 7, "user_name": "Ada" })
  assert_eq(result.edits.map(edit => edit.path), ["$.user_name"])
  assert_eq(result.errors.map(error => (error.path, error.keyword)), [
    ("$.hat", "ambiguous_key"),
    ("$.satt", "key_collision"),
  ])
  let retry = result.format_retry_prompt(schema)
  assert_true(retry.contains("bat and cat"))
  assert_true(retry.contains("compete for $.sat"))
}

///|
test "semantic tie is superseded by a later uniquely closer key" {
  let report = semantic({ "userName": "Ada" }, {
    "properties": { "User_Name2": true, "User_Name3": true, "user_name": true },
  })
  assert_eq(report.value, { "user_name": "Ada" })
  assert_true(report.errors.is_empty())
}

///|
test "semantic false property rule never admits an alias migration" {
  let value : Json = { "userName": "Ada" }
  let report = semantic(value, { "properties": { "user_name": false } })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
}

///|
test "semantic normalized-name ties do not prefer object order" {
  let a : Json = { "properties": { "user_name": true, "userName": true } }
  let b : Json = { "properties": { "userName": true, "user_name": true } }
  let value : Json = { "USERNAME": "Ada" }
  assert_eq(semantic(value, a), semantic(value, b))
  assert_eq(semantic(value, a).errors[0].keyword, "ambiguous_key")
}

///|
test "semantic never moves a colliding alias to a farther free key" {
  let value : Json = { "user_name": "first", "userName": "second" }
  let schema : Json = {
    "properties": { "user_name": true, "user_names": true },
  }
  let result = semantic(value, schema)
  assert_eq(result.value, value)
  assert_true(result.edits.is_empty())
  assert_eq(result.errors[0].keyword, "key_collision")
  assert_eq(result.errors[0].path, "$.userName")
  assert_true(result.format_retry_prompt(schema).contains("$.user_name"))
}

///|
test "semantic rejects all competing aliases instead of picking the first source" {
  let value : Json = { "u_ser": "first", "USER": "second" }
  let report = semantic(value, { "properties": { "user": true } })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
  assert_eq(report.errors.map(e => e.path), ["$.USER", "$.u_ser"])
  assert_eq(report.errors.map(e => e.keyword), [
    "key_collision", "key_collision",
  ])
}

///|
test "semantic combines collision with required error in one retry prompt" {
  let schema : Json = { "properties": { "user": true }, "required": ["user"] }
  let report = semantic({ "u_ser": "first", "USER": "second" }, schema)
  assert_eq(report.errors.map(e => e.path), ["$.USER", "$.u_ser", "$.user"])
  let prompt = report.format_retry_prompt(schema)
  assert_true(prompt.contains("\"path\":\"$.user\""))
  assert_true(prompt.contains("\"path\":\"$.USER\""))
}

///|
test "semantic key aliases do not strip arbitrary punctuation or non-ASCII letters" {
  let value : Json = { "user-name": 1, "user_名": 2, "": 3, "___": 4 }
  let result = semantic(value, {
    "properties": { "username": true, "用户": true },
  })
  assert_eq(result.value, value)
  assert_true(result.errors.is_empty())
  assert_true(result.edits.is_empty())
}

///|
test "semantic preserves nonnormalizable property definitions and unrelated input keys" {
  let value : Json = { "name": 1, "external": false }
  let result = semantic(value, {
    "properties": { "日name": true, "age": true },
  })
  assert_eq(result.value, value)
  assert_true(result.errors.is_empty())
  assert_true(result.edits.is_empty())
}

///|
test "semantic never searches keys longer than the matching budget" {
  let target = "a".repeat(64)
  let source = target + "Z"
  let value = Json::object(Map([(source, Json::number(1.0))]))
  let schema : Json = {
    "required": [target],
    "properties": Json::object(Map([(target, Json::boolean(true))])),
  }
  assert_eq(semantic(value, schema).value, value)
}

///|
test "semantic accepts the exact key length budget at 64 UTF-16 units" {
  let target = "ab".repeat(32)
  let source = "AB".repeat(32)
  expect_key(source, target)
}

///|
test "semantic avoids fuzzy search across a very wide value object" {
  let fields : Map[String, Json] = { "userName": "Ada" }
  for i in 0..<128 {
    fields["unrelated_\{i}"] = Json::null()
  }
  let value = Json::object(fields)
  let report = semantic(value, {
    "properties": { "user_name": true },
    "required": ["user_name"],
  })
  assert_eq(report.value, value)
  assert_eq(report.errors[0].keyword, "required")
}

///|
test "semantic avoids fuzzy search across a very wide schema object" {
  let rules : Map[String, Json] = { "user_name": true }
  for i in 0..<128 {
    rules["unrelated_\{i}"] = Json::boolean(true)
  }
  let value : Json = { "userName": "Ada" }
  let report = semantic(value, {
    "properties": Json::object(rules),
    "required": ["user_name"],
  })
  assert_eq(report.value, value)
  assert_eq(report.errors[0].keyword, "required")
}

///|
test "semantic empty properties leave extra keys alone" {
  let value : Json = { "userName": "Ada" }
  assert_eq(semantic(value, { "properties": {} }).value, value)
}

///|
test "semantic nested path preserves quoted segments and edit sequence" {
  let schema : Json = {
    "properties": {
      "a.b": {
        "items": {
          "properties": { "user_name": { "type": "integer" } },
          "required": ["user_name"],
        },
      },
    },
  }
  let value : Json = { "a.b": [{ "userName": "9007199254740993" }] }
  let result = semantic(value, schema)
  assert_true(result.errors.is_empty())
  assert_eq(result.json, "{\"a.b\":[{\"user_name\":9007199254740993}]}")
  assert_eq(result.edits.map(edit => edit.kind), [
    "rename_key", "string_to_number",
  ])
  assert_eq(result.edits.map(edit => edit.path), [
    "$[\"a.b\"][0].user_name", "$[\"a.b\"][0].user_name",
  ])
  assert_eq(semantic(result.value, schema).edits.length(), 0)
}

///|
test "semantic key option can be disabled without disabling enum recovery" {
  let options = {
    ..@json_repair.CoercionOptions::default().with_semantic(),
    fuzzy_keys: false,
  }
  let report = @json_repair.coerce_with_schema_semantic(
    { "userName": "Ada", "currency": "usd" },
    { "properties": { "user_name": true, "currency": { "enum": ["USD"] } } },
    options~,
  )
  assert_eq(report.value, { "userName": "Ada", "currency": "USD" })
  assert_eq(report.edits.map(e => e.kind), ["normalize_enum"])
}

///|
test "semantic chooses enum case normalization and JSON whitespace trim" {
  let schema : Json = { "enum": [98, "USD", "EUR"] }
  let result = semantic(" \tusd\r\n", schema)
  assert_eq(result.value, Json::string("USD"))
  assert_true(result.errors.is_empty())
  guard result.edits is [edit] else { fail("expected one enum edit") }
  assert_eq(edit.path, "$")
  assert_eq(edit.kind, "normalize_enum")
  assert_eq(edit.before, Json::string(" \tusd\r\n"))
  assert_eq(edit.after, Json::string("USD"))
}

///|
test "semantic allows identical enum entries but rejects distinct case-equivalent choices" {
  assert_eq(
    semantic("usd", { "enum": ["USD", "USD"] }).value,
    Json::string("USD"),
  )
  let schema : Json = { "enum": ["uSd", "USD"] }
  let result = semantic("usd", schema)
  assert_eq(result.value, Json::string("usd"))
  assert_true(result.edits.is_empty())
  assert_eq(result.errors[0].keyword, "enum")
  assert_true(result.format_retry_prompt(schema).contains("one of"))
}

///|
test "semantic preserves an exact enum spelling even with other case matches" {
  let report = semantic("usd", { "enum": ["USD", "usd"] })
  assert_eq(report.value, Json::string("usd"))
  assert_true(report.errors.is_empty())
  assert_true(report.edits.is_empty())
}

///|
test "semantic enum casing never folds unrelated Unicode characters" {
  let report = semantic("\u00C5", { "enum": ["\u00E5"] })
  assert_eq(report.value, Json::string("\u00C5"))
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "enum")
}

///|
test "semantic normalizes ASCII casing inside a multilingual enum token" {
  let report = semantic("usd\u4E2D", { "enum": ["USD\u4E2D"] })
  assert_eq(report.value, Json::string("USD\u4E2D"))
  assert_true(report.errors.is_empty())
}

///|
test "semantic enum recovery validates the entire local rule" {
  let report = semantic("usd", { "enum": ["USD"], "minLength": 4 })
  assert_eq(report.value, Json::string("usd"))
  assert_true(report.edits.is_empty())
  assert_eq(report.errors.map(e => e.keyword), ["enum", "minLength"])
}

///|
test "semantic trim-only enum policy preserves letter case" {
  let options = {
    ..@json_repair.CoercionOptions::default().with_semantic(),
    enum_case: false,
  }
  let schema : Json = { "enum": ["USD"] }
  assert_eq(
    @json_repair.coerce_with_schema_semantic(" USD ", schema, options~).value,
    Json::string("USD"),
  )
  assert_eq(
    @json_repair.coerce_with_schema_semantic(" usd ", schema, options~).value,
    Json::string(" usd "),
  )
}

///|
test "semantic case-only enum policy preserves padding" {
  let options = {
    ..@json_repair.CoercionOptions::default().with_semantic(),
    trim_padding: false,
  }
  let schema : Json = { "enum": ["USD"] }
  assert_eq(
    @json_repair.coerce_with_schema_semantic("usd", schema, options~).value,
    Json::string("USD"),
  )
  assert_eq(
    @json_repair.coerce_with_schema_semantic(" usd ", schema, options~).value,
    Json::string(" usd "),
  )
}

///|
test "semantic disabling both enum flags uses original enum validation" {
  let options = {
    ..@json_repair.CoercionOptions::default().with_semantic(),
    trim_padding: false,
    enum_case: false,
  }
  let result = @json_repair.coerce_with_schema_semantic(
    "usd",
    { "enum": ["USD"] },
    options~,
  )
  assert_true(result.edits.is_empty())
  assert_eq(result.errors[0].keyword, "enum")
}

///|
test "semantic keeps chosen canonical enum whitespace exactly as declared" {
  let report = semantic(" USD ", { "enum": [" USD ", "USD"] })
  assert_eq(report.value, Json::string(" USD "))
  assert_true(report.errors.is_empty())
  assert_true(report.edits.is_empty())
}

///|
test "semantic does not strip whitespace needed by the unique enum choice" {
  let report = semantic(" usd ", { "enum": [" USD "] })
  assert_eq(report.value, Json::string(" USD "))
  assert_true(report.errors.is_empty())
  assert_eq(report.edits[0].kind, "normalize_enum")
}

///|
test "semantic rejects competing whitespace-preserving and trimmed enum choices" {
  let report = semantic(" usd ", { "enum": [" USD ", "USD"] })
  assert_eq(report.value, Json::string(" usd "))
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "enum")
}

///|
test "semantic trims numeric padding and preserves large integer text in JSON and audits" {
  let result = semantic("\t 9007199254740993\r\n", { "type": "integer" })
  assert_eq(result.json, "9007199254740993")
  assert_eq(result.edits.map(e => e.kind), [
    "trim_scalar_padding", "string_to_number",
  ])
  assert_true(
    @json.to_json(result).stringify().contains("\"after\":9007199254740993"),
  )
  assert_true(result.errors.is_empty())
}

///|
test "semantic trims boolean padding without accepting aliases" {
  let result = semantic("\t true \n", { "type": "boolean" })
  assert_eq(result.json, "true")
  assert_eq(result.edits.map(e => e.kind), [
    "trim_scalar_padding", "string_to_boolean",
  ])
  assert_eq(semantic(" TRUE ", { "type": "boolean" }).errors[0].keyword, "type")
}

///|
test "semantic trims false padding as a JSON literal" {
  let result = semantic(" false ", { "type": ["boolean"] })
  assert_eq(result.json, "false")
  assert_true(result.errors.is_empty())
}

///|
test "semantic leaves padded numbers unmodified when range would still fail" {
  let result = semantic(" 9007199254740993 ", {
    "type": "integer",
    "maximum": 1.0,
  })
  assert_eq(result.value, Json::string(" 9007199254740993 "))
  assert_true(result.edits.is_empty())
  assert_eq(result.errors[0].keyword, "type")
}

///|
test "semantic does not trim arbitrary strings or accept stripped unit suffixes" {
  let notes = semantic("  keep me \n", { "type": "string" })
  assert_eq(notes.value, Json::string("  keep me \n"))
  assert_true(notes.errors.is_empty())
  assert_eq(semantic(" 42ms ", { "type": "number" }).errors[0].keyword, "type")
}

///|
test "semantic uses only JSON whitespace for padding" {
  let input = "\u00A042\u00A0"
  let result = semantic(Json::string(input), { "type": "number" })
  assert_eq(result.value, Json::string(input))
  assert_true(result.edits.is_empty())
}

///|
test "semantic padding respects disabled primitive conversions" {
  let base : @json_repair.CoercionOptions = {
    number_strings: false,
    boolean_strings: false,
    wrap_scalar_arrays: false,
  }
  let options = base.with_semantic()
  let number = @json_repair.coerce_with_schema_semantic(
    " 42 ",
    { "type": "integer" },
    options~,
  )
  let boolean = @json_repair.coerce_with_schema_semantic(
    " true ",
    { "type": "boolean" },
    options~,
  )
  assert_true(number.edits.is_empty())
  assert_true(boolean.edits.is_empty())
  assert_eq(number.errors[0].keyword, "type")
  assert_eq(boolean.errors[0].keyword, "type")
}

///|
test "semantic wraps a single padded integer with a stable nested audit" {
  let schema : Json = { "type": "array", "items": { "type": "integer" } }
  let report = semantic(" 9007199254740993 ", schema)
  assert_eq(report.json, "[9007199254740993]")
  assert_eq(report.edits.map(e => e.kind), [
    "wrap_scalar", "trim_scalar_padding", "string_to_number",
  ])
  assert_eq(report.edits.map(e => e.path), ["$", "$[0]", "$[0]"])
  assert_true(report.errors.is_empty())
}

///|
test "semantic wraps a single canonicalized enum token" {
  let result = semantic(" usd ", {
    "type": "array",
    "items": { "enum": ["USD"] },
  })
  assert_eq(result.value, ["USD"])
  assert_eq(result.edits.map(e => e.kind), ["wrap_scalar", "normalize_enum"])
}

///|
test "semantic array edits roll back when the enclosing enum fails" {
  let report = semantic(" usd ", {
    "type": "array",
    "items": { "enum": ["USD"] },
    "enum": [["EUR"]],
  })
  assert_eq(report.value, Json::string(" usd "))
  assert_true(report.edits.is_empty())
  assert_eq(report.errors.map(e => e.keyword), ["type", "enum"])
}

///|
test "semantic single-value mode never invents nested array layers" {
  let result = semantic(3, { "type": "array", "items": { "type": "array" } })
  assert_eq(result.value, Json::number(3.0))
  assert_true(result.edits.is_empty())
}

///|
test "semantic single-value flag can be disabled independently" {
  let options = {
    ..@json_repair.CoercionOptions::default().with_semantic(),
    wrap_singletons: false,
  }
  let report = @json_repair.coerce_with_schema_semantic(
    1,
    { "type": "array" },
    options~,
  )
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "semantic mode leaves boolean schemas and invalid definitions unchanged" {
  let value : Json = { "userName": "Ada" }
  assert_true(semantic(value, true).errors.is_empty())
  assert_eq(semantic(value, false).value, value)
  let schema : Json = { "properties": { "user_name": { "type": "unknown" } } }
  let bad_schema = semantic(value, schema)
  assert_eq(bad_schema.value, value)
  assert_true(bad_schema.edits.is_empty())
  assert_true(
    bad_schema.format_retry_prompt(schema).has_prefix("Fix the tool schema"),
  )
}

///|
test "semantic successful report retry prompt is empty after all changes" {
  let schema : Json = { "enum": ["USD"] }
  let report = semantic("usd", schema)
  assert_eq(report.format_retry_prompt(schema), "")
}

///|
test "semantic retry prompt counts and bounds conflicting aliases" {
  let fields : Map[String, Json] = Map([])
  for length in 1..<=18 {
    fields["_".repeat(length) + "user"] = Json::number(1.0)
  }
  let schema : Json = { "properties": { "user": true } }
  let result = semantic(Json::object(fields), schema)
  assert_eq(result.errors.length(), 18)
  assert_true(result.edits.is_empty())
  assert_true(result.format_retry_prompt(schema).contains("\"remaining\":2"))
}

///|
fn oracle_key_distance(left : StringView, right : StringView) -> Int32 {
  let mut previous = Array::makei(right.length() + 1, index => index)
  for i in 0..<left.length() {
    let row = Array::make(right.length() + 1, i + 1)
    for j in 0..<right.length() {
      let replace = previous[j] + (if left[i] == right[j] { 0 } else { 1 })
      row[j + 1] = replace.min(previous[j + 1] + 1).min(row[j] + 1)
    }
    previous = row
  }
  previous[right.length()]
}

///|
fn random_semantic_key(rng : FuzzPrng, length : Int32) -> String {
  let out = StringBuilder()
  for _ in 0..<length {
    out.write_char((97 + rng.pick(5)).unsafe_to_char())
  }
  out.to_string()
}

///|
fn mutate_semantic_key(rng : FuzzPrng, key : String) -> String {
  let at = rng.pick(key.length())
  let out = StringBuilder()
  out.write_string(key.unsafe_substring(start=0, end=at))
  let operation = rng.pick(3)
  if operation != 0 {
    out.write_string(random_semantic_key(rng, 1))
  }
  let skip = if operation == 2 { 0 } else { 1 }
  out.write_string(key.unsafe_substring(start=at + skip, end=key.length()))
  out.to_string()
}

///|
test "semantic compares 512 fixed-seed nested key plans to a full edit-distance oracle" {
  let rng : FuzzPrng = { state: 0x90E1D43CU, }
  for _ in 0..<512 {
    let input = random_semantic_key(rng, 4 + rng.pick(10))
    let item_rule : Json = { "type": "integer" }
    let rules : Map[String, Json] = Map([])
    for _ in 0..<(1 + rng.pick(5)) {
      let mut name = input
      for _ in 0..<(1 + rng.pick(3)) {
        name = mutate_semantic_key(rng, name)
      }
      if name != input {
        rules[name] = item_rule
      }
    }
    let winners = []
    let mut best = 3
    for name in rules.keys() {
      let distance = oracle_key_distance(input[:], name[:])
      let budget = if input.length().min(name.length()) >= 8 { 2 } else { 1 }
      if distance <= budget {
        if distance < best {
          winners.clear()
          best = distance
        }
        if distance == best {
          winners.push(name)
        }
      }
    }
    let original : Map[String, Json] = Map([
      (input, Json::string("9007199254740993")),
    ])
    let mut occupied = false
    if winners is [target] && rng.pick(3) == 0 {
      original[target] = Json::number(3.0)
      occupied = true
    }
    let value : Json = { "args": [Json::object(original)] }
    let schema : Json = {
      "properties": {
        "args": { "items": { "properties": Json::object(rules) } },
      },
    }
    let result = semantic(value, schema)
    let repeated = semantic(result.value, schema)
    if winners is [target] && !occupied {
      assert_eq(result.json, "{\"args\":[{\"\{target}\":9007199254740993}]}")
      assert_eq(result.edits.map(edit => edit.path), [
        "$.args[0]." + target,
        "$.args[0]." + target,
      ])
      assert_true(result.errors.is_empty())
    } else {
      assert_eq(result.value, value)
      assert_true(result.edits.is_empty())
      let expected = if winners.length() > 1 {
        ["ambiguous_key"]
      } else if occupied {
        ["key_collision"]
      } else {
        []
      }
      assert_eq(result.errors.map(error => error.keyword), expected)
    }
    assert_eq(repeated.value, result.value)
    assert_true(repeated.edits.is_empty())
    assert_eq(repeated.errors, result.errors)
  }
}
