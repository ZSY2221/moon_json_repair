///|
fn typed_report(
  input : String,
  schema : Json,
) -> @json_repair.CoercionReport raise {
  let value = @json.parse(input[:], preserve_number_repr=true)
  @json_repair.coerce_with_schema(value, schema)
}

///|
fn array_coercion() -> @json_repair.CoercionOptions {
  { ..@json_repair.CoercionOptions::default(), wrap_scalar_arrays: true, }
}

///|
fn prompt_payload(value : Json, schema : Json) -> Json raise {
  let prompt = @json_repair.format_retry_prompt(value, schema)
  guard prompt[:].split_once("\n") is Some((_, payload)) else {
    fail("missing retry prompt payload")
  }
  @json.parse(payload, preserve_number_repr=true)
}

///|
test "coercion records exact decimal conversion" {
  let report = typed_report("\"42.50\"", { "type": "number" })
  assert_eq(report.json, "42.50")
  assert_true(report.errors.is_empty())
  guard report.edits is [edit] else { fail("expected one type edit") }
  assert_eq(edit.path, "$")
  assert_eq(edit.kind, "string_to_number")
  assert_eq(edit.before, Json::string("42.50"))
  assert_eq(edit.after.stringify(), "42.50")
}

///|
test "coercion preserves integer beyond binary64 and compares exact bounds" {
  let schema_text =
    #|{"type":"integer","maximum":9007199254740992}
  let schema = @json.parse(schema_text[:], preserve_number_repr=true)
  let report = typed_report("\"9007199254740993\"", schema)
  assert_eq(report.json, "9007199254740993")
  guard report.errors is [error] else { fail("expected one bound error") }
  assert_eq(error.keyword, "maximum")
  assert_eq(error.path, "$")
}

///|
test "coercion retains finite JSON lexemes larger than binary64" {
  let report = typed_report("\"1e999\"", { "type": "integer" })
  assert_eq(report.json, "1e999")
  assert_true(report.errors.is_empty())
}

///|
test "coercion retains negative zero lexeme" {
  let report = typed_report("\"-0\"", { "type": "integer" })
  assert_eq(report.json, "-0")
  assert_true(report.errors.is_empty())
}

///|
test "coercion accepts mathematically integral exponents" {
  let report = typed_report("\"1.20e+2\"", { "type": "integer" })
  assert_eq(report.json, "1.20e+2")
  assert_true(report.errors.is_empty())
}

///|
test "coercion rejects nonintegral input for integer targets" {
  let report = typed_report("\"1e-400\"", { "type": "integer" })
  assert_eq(report.json, "\"1e-400\"")
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion does not infer number type from range alone" {
  let report = typed_report("\"42\"", { "minimum": 0 })
  assert_eq(report.value, Json::string("42"))
  assert_true(report.errors.is_empty())
  assert_true(report.edits.is_empty())
}

///|
test "coercion supports explicit singleton type arrays" {
  let report = typed_report("\"123\"", { "type": ["integer"] })
  assert_eq(report.json, "123")
  assert_true(report.errors.is_empty())
}

///|
test "coercion leaves ambiguous unions for the caller" {
  let report = typed_report("\"1\"", { "type": ["number", "boolean"] })
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion leaves values valid under a union unchanged" {
  let report = typed_report("\"true\"", { "type": ["string", "boolean"] })
  assert_eq(report.value, Json::string("true"))
  assert_true(report.edits.is_empty())
  assert_true(report.errors.is_empty())
}

///|
test "coercion only accepts lowercase true and false" {
  let report = typed_report("[\"true\",\"false\",\"True\",\" false\"]", {
    "type": "array",
    "items": { "type": "boolean" },
  })
  assert_eq(report.json, "[true,false,\"True\",\" false\"]")
  assert_eq(report.edits.map(edit => edit.path), ["$[0]", "$[1]"])
  assert_eq(report.edits.map(edit => edit.kind), [
    "string_to_boolean", "string_to_boolean",
  ])
  assert_eq(report.errors.map(error => error.path), ["$[2]", "$[3]"])
}

///|
test "coercion can disable numeric conversions while preserving booleans" {
  let options = {
    ..@json_repair.CoercionOptions::default(),
    number_strings: false,
  }
  let report = @json_repair.coerce_with_schema(
    { "n": "42", "b": "false" },
    { "properties": { "n": { "type": "number" }, "b": { "type": "boolean" } } },
    options~,
  )
  assert_eq(report.value, { "n": "42", "b": false })
  assert_eq(report.edits.map(edit => edit.path), ["$.b"])
  assert_eq(report.errors.map(error => error.path), ["$.n"])
}

///|
test "coercion can disable boolean conversions" {
  let options = {
    ..@json_repair.CoercionOptions::default(),
    boolean_strings: false,
  }
  let report = @json_repair.coerce_with_schema(
    "true",
    { "type": "boolean" },
    options~,
  )
  assert_eq(report.json, "\"true\"")
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion traverses nested objects without mutating input or assigning unknown keys" {
  let original : Json = {
    "args": { "z": "true", "a": "12.5", "other": "false" },
  }
  let before = original.stringify()
  let report = @json_repair.coerce_with_schema(original, {
    "properties": {
      "args": {
        "properties": {
          "z": { "type": "boolean" },
          "a": { "type": "number" },
          "missing": { "type": "boolean" },
        },
      },
    },
  })
  assert_eq(original.stringify(), before)
  assert_eq(report.value, { "args": { "z": true, "a": 12.5, "other": "false" } })
  assert_eq(report.edits.map(edit => edit.path), ["$.args.a", "$.args.z"])
  assert_true(report.errors.is_empty())
}

///|
test "coercion quotes unusual keys in audit paths" {
  let report = @json_repair.coerce_with_schema(
    { "foo.bar": { "a\"b": "true" } },
    {
      "properties": {
        "foo.bar": { "properties": { "a\"b": { "type": "boolean" } } },
      },
    },
  )
  assert_eq(report.edits[0].path, "$[\"foo.bar\"][\"a\\\"b\"]")
}

///|
test "coercion leaves missing properties and negative amounts visible" {
  let report = @json_repair.coerce_with_schema({ "amount": "-1" }, {
    "required": ["currency"],
    "properties": { "amount": { "type": "number", "minimum": 0 } },
  })
  assert_eq(report.value, { "amount": -1 })
  assert_eq(report.errors.map(error => error.keyword), ["required", "minimum"])
  assert_eq(report.errors.map(error => error.path), ["$.currency", "$.amount"])
}

///|
test "coercion skips malformed schema entirely" {
  let value : Json = { "amount": "42" }
  let schema : Json = {
    "properties": { "amount": { "type": "number" } },
    "unsupported": true,
  }
  let report = @json_repair.coerce_with_schema(value, schema)
  assert_eq(report.value, value)
  assert_eq(report.errors, @json_repair.validate(value, schema))
  assert_true(report.edits.is_empty())
}

///|
test "coercion leaves boolean schemas unchanged" {
  let allowed = @json_repair.coerce_with_schema("42", true)
  assert_eq(allowed.value, Json::string("42"))
  assert_true(allowed.edits.is_empty())
  assert_true(allowed.errors.is_empty())
  let denied = @json_repair.coerce_with_schema("42", false)
  assert_true(denied.edits.is_empty())
  assert_eq(denied.errors[0].keyword, "false")
}

///|
test "coercion requires explicit scalar wrapping" {
  let report = @json_repair.coerce_with_schema(12, { "type": "array" })
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion wraps scalar under array-only schema" {
  let report = @json_repair.coerce_with_schema(
    "code",
    { "type": "array" },
    options=array_coercion(),
  )
  assert_eq(report.value, ["code"])
  assert_eq(report.edits[0].kind, "wrap_scalar")
  assert_eq(report.edits[0].path, "$")
  assert_eq(report.edits[0].before, Json::string("code"))
  assert_eq(report.edits[0].after, ["code"])
}

///|
test "coercion wraps then converts array item with separate audit paths" {
  let report = @json_repair.coerce_with_schema(
    { "ids": "9007199254740993" },
    {
      "properties": {
        "ids": { "type": "array", "items": { "type": "integer" } },
      },
    },
    options=array_coercion(),
  )
  assert_eq(report.json, "{\"ids\":[9007199254740993]}")
  assert_eq(report.edits.map(edit => edit.path), ["$.ids", "$.ids[0]"])
  assert_eq(report.edits.map(edit => edit.kind), [
    "wrap_scalar", "string_to_number",
  ])
  assert_eq(report.edits[0].after, ["9007199254740993"])
  assert_true(report.errors.is_empty())
}

///|
test "coercion rolls back wrapping and speculative item changes on constraint failure" {
  let report = @json_repair.coerce_with_schema(
    "-3",
    { "type": "array", "items": { "type": "number", "minimum": 0 } },
    options=array_coercion(),
  )
  assert_eq(report.value, Json::string("-3"))
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion wrapping checks whole-array enum constraints" {
  let report = @json_repair.coerce_with_schema(
    1,
    { "type": "array", "items": { "type": "number" }, "enum": [[2]] },
    options=array_coercion(),
  )
  assert_eq(report.value, Json::number(1.0))
  assert_true(report.edits.is_empty())
}

///|
test "coercion does not repeatedly nest arrays while probing a scalar wrap" {
  let report = @json_repair.coerce_with_schema(
    1,
    { "type": "array", "items": { "type": "array" } },
    options=array_coercion(),
  )
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion does not wrap null or objects" {
  let schema : Json = { "type": "array" }
  let options = array_coercion()
  let absent = @json_repair.coerce_with_schema(null, schema, options~)
  let object = @json_repair.coerce_with_schema(
    { "present": true },
    schema,
    options~,
  )
  assert_true(absent.edits.is_empty())
  assert_true(object.edits.is_empty())
  assert_eq(absent.errors[0].keyword, "type")
  assert_eq(object.errors[0].keyword, "type")
}

///|
test "coercion is idempotent on successful nested values" {
  let schema : Json = { "items": { "type": "integer" } }
  let input : Json = ["12", "42"]
  let first = @json_repair.coerce_with_schema(input, schema)
  let again = @json_repair.coerce_with_schema(first.value, schema)
  assert_eq(first.json, "[12,42]")
  assert_eq(again.value, first.value)
  assert_true(again.edits.is_empty())
  assert_true(again.errors.is_empty())
  assert_eq(input, ["12", "42"])
}

///|
test "coercion lossless JSON serialization retains parsed numeric token twice" {
  let report = typed_report("\"9007199254740993\"", { "type": "integer" })
  let json = @json.to_json(report).stringify()
  assert_true(json.contains("\"value\":9007199254740993"))
  assert_true(json.contains("\"before\":\"9007199254740993\""))
  assert_true(json.contains("\"after\":9007199254740993"))
}

///|
test "retry formatter returns empty text for valid tool arguments" {
  assert_eq(
    @json_repair.format_retry_prompt({ "a": 1 }, {
      "properties": { "a": { "minimum": 0 } },
    }),
    "",
  )
}

///|
test "retry formatter gives negative amount and exact boundary example" {
  let payload = prompt_payload({ "args": { "amount": -2 } }, {
    "properties": {
      "args": { "properties": { "amount": { "type": "number", "minimum": 0 } } },
    },
  })
  assert_eq(payload, {
    "fix": [
      {
        "path": "$.args.amount",
        "expected": "expected number >= 0",
        "actual": -2,
        "example": 0,
      },
    ],
  })
}

///|
test "retry formatter gives exact oversized integer and maximum" {
  let value = @json.parse("9007199254740993", preserve_number_repr=true)
  let schema = @json.parse(
    "{\"maximum\":9007199254740992}",
    preserve_number_repr=true,
  )
  let payload = prompt_payload(value, schema).stringify()
  assert_true(
    payload.contains("\"expected\":\"expected number <= 9007199254740992\""),
  )
  assert_true(payload.contains("\"actual\":9007199254740993"))
  assert_true(payload.contains("\"example\":9007199254740992"))
}

///|
test "retry formatter shows a short enum and a valid example" {
  let payload = prompt_payload("BTC", { "enum": ["USD", "SGD"] })
  assert_eq(payload, {
    "fix": [
      {
        "path": "$",
        "expected": "one of [\"USD\",\"SGD\"]",
        "actual": "BTC",
        "example": "USD",
      },
    ],
  })
}

///|
test "retry formatter chooses an enum example satisfying the complete rule" {
  let payload = prompt_payload(4, { "minimum": 5, "enum": [2, 10] })
  guard payload
    is { "fix": Array([Object(enum_issue), Object(range_issue)]), .. } else {
    fail("expected enum and range issue")
  }
  assert_eq(enum_issue["example"], Json::number(10.0))
  assert_eq(range_issue["example"], Json::number(10.0))
}

///|
test "retry formatter handles item type with minimal example" {
  let payload = prompt_payload({ "args": { "tags": ["existing", 3] } }, {
    "properties": {
      "args": {
        "properties": {
          "tags": {
            "type": "array",
            "items": { "type": "string", "minLength": 1 },
          },
        },
      },
    },
  })
  assert_eq(payload, {
    "fix": [
      {
        "path": "$.args.tags[1]",
        "expected": "expected string",
        "actual": 3,
        "example": "x",
      },
    ],
  })
}

///|
test "retry formatter missing required property uses child definition" {
  let payload = prompt_payload({}, {
    "required": ["deposit"],
    "properties": { "deposit": { "type": "number", "minimum": 12 } },
  })
  assert_eq(payload, {
    "fix": [
      {
        "path": "$.deposit",
        "expected": "required property is missing",
        "example": 12,
      },
    ],
  })
}

///|
test "retry formatter missing required property without schema has no fabricated value" {
  let expected : Json = {
    "fix": [{ "path": "$.x", "expected": "required property is missing" }],
  }
  assert_eq(prompt_payload({}, { "required": ["x"] }), expected)
  assert_eq(
    prompt_payload({}, { "required": ["x"], "properties": {} }),
    expected,
  )
}

///|
test "retry formatter uses exact path for required special key" {
  let payload = prompt_payload({}, {
    "required": ["a.b"],
    "properties": { "a.b": { "type": "boolean" } },
  })
  assert_eq(payload, {
    "fix": [
      {
        "path": "$[\"a.b\"]",
        "expected": "required property is missing",
        "example": false,
      },
    ],
  })
}

///|
test "retry formatter distinguishes schema configuration errors from bad arguments" {
  let schema : Json = { "type": "bad_type" }
  assert_true(
    @json_repair.format_retry_prompt(3, schema).has_prefix(
      "Fix the tool schema before retrying.\n",
    ),
  )
  assert_eq(prompt_payload(3, schema), {
    "fix": [{ "path": "$schema.type", "expected": "unknown type bad_type" }],
  })
}

///|
test "retry formatter never supplies an example for false schema" {
  assert_eq(prompt_payload(true, false), {
    "fix": [
      { "path": "$", "expected": "rejected by false schema", "actual": true },
    ],
  })
}

///|
test "retry formatter measures Unicode length in code points" {
  let payload = prompt_payload("🛰", { "type": "string", "minLength": 2 })
  assert_eq(payload, {
    "fix": [
      {
        "path": "$",
        "expected": "expected at least 2 Unicode code points",
        "actual": "🛰",
        "example": "xx",
      },
    ],
  })
}

///|
test "retry formatter validates string bound examples" {
  let payload = prompt_payload("too long", { "type": "string", "maxLength": 0 })
  assert_eq(payload, {
    "fix": [
      {
        "path": "$",
        "expected": "expected at most 0 Unicode code points",
        "actual": "too long",
        "example": "",
      },
    ],
  })
}

///|
test "retry formatter truncates long scalar values without breaking Unicode" {
  let value = Json::string("🛰".repeat(80))
  let payload = prompt_payload(value, { "type": "boolean" })
  guard payload
    is {
      "fix": Array(
        [
          {
            "actual": String(actual),
            "actual_truncated": True,
            "example": False,
            ..
          },
        ],
      ),
      ..
    } else {
    fail("expected bounded invalid value and example")
  }
  assert_eq(actual, "🛰".repeat(36) + "…")
}

///|
test "retry formatter bounds large input arrays and objects" {
  let payload = prompt_payload(
    { "a": [1, 2, 3, 4], "b": { "key": { "next": { "deep": "value" } } } },
    { "properties": { "a": { "type": "boolean" }, "b": { "type": "null" } } },
  )
  assert_eq(payload, {
    "fix": [
      {
        "path": "$.a",
        "expected": "expected boolean",
        "actual": "<array>",
        "actual_truncated": true,
        "example": false,
      },
      {
        "path": "$.b",
        "expected": "expected null",
        "actual": "<object>",
        "actual_truncated": true,
        "example": null,
      },
    ],
  })
}

///|
test "retry formatter only emits valid examples for conflicting bounds" {
  let payload = prompt_payload(3, {
    "type": "number",
    "minimum": 4,
    "maximum": 2,
  })
  guard payload is { "fix": Array([Object(first), Object(second)]), .. } else {
    fail("expected two boundary failures")
  }
  assert_false(first.contains("example"))
  assert_false(second.contains("example"))
}

///|
test "retry formatter caps issue count and reports remaining diagnostics" {
  let value = Json::array(Array::make(20, Json::string("bad")))
  let payload = prompt_payload(value, { "items": { "type": "number" } })
  guard payload is { "fix": Array(issues), "remaining": Number(count, ..), .. } else {
    fail("expected omitted issue count")
  }
  assert_eq(issues.length(), 16)
  assert_eq(count, 4.0)
  assert_true(issues[15] is { "path": String("$[15]"), .. })
}

///|
test "retry formatter chooses valid minimal array and object examples" {
  let array_payload = prompt_payload("missing brackets", { "type": "array" })
  let object_payload = prompt_payload("missing object", { "type": "object" })
  assert_true(
    array_payload is { "fix": Array([{ "example": Array([]), .. }]), .. },
  )
  assert_true(
    object_payload is { "fix": Array([{ "example": Object(fields), .. }]), .. } &&
    fields.is_empty(),
  )
}

///|
test "retry formatter bounds long number previews without rounding" {
  let number = "9".repeat(130)
  let value = @json.parse(number[:], preserve_number_repr=true)
  let payload = prompt_payload(value, { "type": "boolean" })
  guard payload
    is {
      "fix": Array(
        [{ "actual": String(preview), "actual_truncated": True, .. }],
      ),
      ..
    } else {
    fail("expected long number to be represented by a text preview")
  }
  assert_eq(preview, "9".repeat(72) + "…")
}

///|
test "retry formatter retains actual small structured value" {
  let payload = prompt_payload({ "a": [1, false] }, { "type": "string" })
  assert_true(
    payload
    is {
      "fix": Array(
        [{ "actual": { "a": Array([Number(1.0, ..), False]), .. }, .. }],
      ),
      ..
    },
  )
}

///|
test "coercion rejects hexadecimal numeric strings" {
  let value = Json::string("0x10")
  let report = @json_repair.coerce_with_schema(value, { "type": "number" })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion rejects explicit plus in numeric strings" {
  let value = Json::string("+10")
  let report = @json_repair.coerce_with_schema(value, { "type": "number" })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion rejects leading zero in numeric strings" {
  let value = Json::string("042")
  let report = @json_repair.coerce_with_schema(value, { "type": "number" })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion rejects leading decimal dot in numeric strings" {
  let value = Json::string(".5")
  let report = @json_repair.coerce_with_schema(value, { "type": "number" })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion rejects trailing decimal dot in numeric strings" {
  let value = Json::string("5.")
  let report = @json_repair.coerce_with_schema(value, { "type": "number" })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion rejects leading whitespace in numeric strings" {
  let value = Json::string(" 42")
  let report = @json_repair.coerce_with_schema(value, { "type": "number" })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion rejects trailing whitespace in numeric strings" {
  let value = Json::string("42 ")
  let report = @json_repair.coerce_with_schema(value, { "type": "number" })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion rejects trailing junk in numeric strings" {
  let value = Json::string("42ms")
  let report = @json_repair.coerce_with_schema(value, { "type": "number" })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion rejects empty numeric strings" {
  let value = Json::string("")
  let report = @json_repair.coerce_with_schema(value, { "type": "number" })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion rejects nonfinite spellings" {
  let value = Json::string("Infinity")
  let report = @json_repair.coerce_with_schema(value, { "type": "number" })
  assert_eq(report.value, value)
  assert_true(report.edits.is_empty())
  assert_eq(report.errors[0].keyword, "type")
}

///|
test "coercion preserves a property map when no field requires edits" {
  let value : Json = { "amount": 12, "flag": false }
  let schema : Json = {
    "properties": {
      "amount": { "type": "number" },
      "flag": { "type": "boolean" },
      "optional": { "type": "integer" },
    },
  }
  let report = @json_repair.coerce_with_schema(value, schema)
  assert_eq(report.value, value)
  assert_eq(report.json, value.stringify())
  assert_true(report.edits.is_empty())
  assert_true(report.errors.is_empty())
}

///|
test "schema validation bounds traversal of an unused recursive item definition" {
  let mut schema = Json::boolean(true)
  for _ in 0..<257 {
    schema = { "items": schema }
  }
  let errors = @json_repair.validate([], schema)
  guard errors is [error] else { fail("expected one depth error") }
  assert_eq(error.keyword, "depth")
  assert_eq(error.path, "$schema" + ".items".repeat(257))
}

///|
test "enum equality stops at its complexity budget for deeply nested arguments" {
  let mut value = Json::number(1.0)
  for _ in 0..<256 {
    value = Json::array([value])
  }
  assert_true(@json_repair.validate(value, { "enum": [value] }).is_empty())
  let too_deep = Json::array([value])
  let errors = @json_repair.validate(too_deep, { "enum": [too_deep] })
  assert_eq(errors.map(error => error.keyword), ["enum"])
}

///|
test "enum comparison rejects arrays with a shared prefix but extra elements" {
  let errors = @json_repair.validate([1, 2, 3], { "enum": [[1, 2], [1]] })
  assert_eq(errors.map(error => error.keyword), ["enum"])
}

///|
test "enum comparison rejects objects that only match a subset of the fields" {
  let errors = @json_repair.validate({ "user": "Ada", "admin": true }, {
    "enum": [{ "user": "Ada" }],
  })
  assert_eq(errors.map(error => error.keyword), ["enum"])
}

///|
test "retry formatter caps definition diagnostics before retrying arguments" {
  let properties : Map[String, Json] = Map([])
  for n in 0..<20 {
    properties["p\{n}"] = { "type": "not-a-schema-type" }
  }
  let schema : Json = { "properties": Json::object(properties) }
  let payload = prompt_payload({}, schema)
  guard payload is { "fix": Array(issues), "remaining": Number(count, ..), .. } else {
    fail("expected an omitted schema diagnostic count")
  }
  assert_eq(issues.length(), 16)
  assert_eq(count, 4.0)
  assert_true(issues[0] is { "path": String("$schema.properties.p0.type"), .. })
}

///|
test "retry formatter preserves exact decimal bounds even with no short example" {
  let huge = "1e" + "9".repeat(200)
  let bound = @json.parse(huge[:], preserve_number_repr=true)
  let payload = prompt_payload(3, { "type": "number", "minimum": bound })
  guard payload is { "fix": Array([Object(issue)]), .. } else {
    fail("expected one range diagnostic")
  }
  assert_eq(issue["actual"], Json::number(3.0))
  assert_false(issue.contains("example"))
  assert_true(issue["expected"] is String(message) && message.has_suffix("…"))
}
