///|
fn validation_json(value : Json, schema : Json) -> Json {
  Json::array(
    @json_repair.validate(value, schema).map(error => error.to_json()),
  )
}

///|
fn validation_locations(value : Json, schema : Json) -> Array[(String, String)] {
  @json_repair.validate(value, schema).map(error => (error.path, error.keyword))
}

///|
test "schema accepts an unspecified instance shape" {
  assert_true(
    @json_repair.validate({ "extra": [false, null] }, Json::empty_object()).is_empty(),
  )
}

///|
test "schema true accepts any instance" {
  assert_true(@json_repair.validate(null, true).is_empty())
}

///|
test "schema false fails at the instance root" {
  assert_eq(validation_locations(1, false), [("$", "false")])
}

///|
test "schema validates all basic JSON types" {
  let cases : Array[(Json, String)] = [
    (null, "null"),
    (false, "boolean"),
    ([1], "array"),
    ({ "a": 1 }, "object"),
    (1.5, "number"),
    ("hello", "string"),
    (1, "integer"),
  ]
  for entry in cases {
    let (value, name) = entry
    let schema : Json = { "type": Json::string(name) }
    assert_true(@json_repair.validate(value, schema).is_empty())
  }
}

///|
test "schema reports a typed instance mismatch" {
  let expected : Json = [
    { "path": "$", "keyword": "type", "message": "expected boolean" },
  ]
  assert_eq(validation_json("true", { "type": "boolean" }), expected)
}

///|
test "schema type union permits null" {
  assert_true(
    @json_repair.validate(null, { "type": ["object", "null"] }).is_empty(),
  )
}

///|
test "schema type union rejects values outside the union" {
  assert_eq(validation_locations(1, { "type": ["string", "null"] }), [
    ("$", "type"),
  ])
}

///|
test "schema integer accepts a decimal with zero fraction" {
  let value = Json::number(12.0, repr="12.000")
  assert_true(@json_repair.validate(value, { "type": "integer" }).is_empty())
}

///|
test "schema integer rejects a fraction" {
  assert_eq(validation_locations(1.25, { "type": "integer" }), [("$", "type")])
}

///|
test "schema integer checks decimal source when Double rounds to integer" {
  let value = Json::number(1.0, repr="1.00000000000000001")
  assert_eq(validation_locations(value, { "type": "integer" }), [("$", "type")])
}

///|
test "schema integer supports positive scientific exponents" {
  let value = Json::number(1230.0, repr="1.230e+3")
  assert_true(@json_repair.validate(value, { "type": "integer" }).is_empty())
}

///|
test "schema required reports missing field paths in declaration order" {
  assert_eq(
    validation_locations({ "present": 1 }, { "required": ["z", "present", "a"] }),
    [("$.z", "required"), ("$.a", "required")],
  )
}

///|
test "schema required regards explicit null as present" {
  assert_true(
    @json_repair.validate({ "nullable": null }, { "required": ["nullable"] }).is_empty(),
  )
}

///|
test "schema properties permit missing optional fields and extra fields" {
  let value : Json = { "region": "north" }
  let schema : Json = { "properties": { "email": { "type": "string" } } }
  assert_true(@json_repair.validate(value, schema).is_empty())
}

///|
test "schema checks optional fields when supplied" {
  let schema : Json = { "properties": { "email": { "type": "string" } } }
  assert_eq(validation_locations({ "email": null }, schema), [
    ("$.email", "type"),
  ])
}

///|
test "schema orders independent errors by property name" {
  let value : Json = { "z": false, "a": false }
  let schema : Json = {
    "properties": { "z": { "type": "number" }, "a": { "type": "number" } },
  }
  let expected : Json = [
    { "path": "$.a", "keyword": "type", "message": "expected number" },
    { "path": "$.z", "keyword": "type", "message": "expected number" },
  ]
  assert_eq(validation_json(value, schema), expected)
}

///|
test "schema applies keywords only to their corresponding instance types" {
  let schema : Json = {
    "minLength": 3,
    "minimum": 50,
    "required": ["arg"],
    "items": false,
  }
  assert_true(@json_repair.validate(false, schema).is_empty())
}

///|
test "schema enum matches null and scalar values without coercion" {
  let schema : Json = { "enum": [null, "true", 1] }
  assert_true(@json_repair.validate(null, schema).is_empty())
  assert_eq(validation_locations(true, schema), [("$", "enum")])
}

///|
test "schema enum ignores object key order at every nesting level" {
  let value : Json = { "b": 2, "a": [{ "y": 2, "x": 1 }] }
  let schema : Json = { "enum": [{ "a": [{ "x": 1, "y": 2 }], "b": 2 }] }
  assert_true(@json_repair.validate(value, schema).is_empty())
}

///|
test "schema enum preserves array order inside objects" {
  let schema : Json = { "enum": [{ "args": [1, 2] }] }
  assert_eq(validation_locations({ "args": [2, 1] }, schema), [("$", "enum")])
}

///|
test "schema includes numeric range boundaries" {
  let schema : Json = { "minimum": -2.5, "maximum": 5 }
  assert_true(@json_repair.validate(-2.5, schema).is_empty())
  assert_true(@json_repair.validate(5, schema).is_empty())
}

///|
test "schema minimum reports the exact tool argument path" {
  let value : Json = { "args": { "amount": -0.01 } }
  let schema : Json = {
    "properties": { "args": { "properties": { "amount": { "minimum": 0 } } } },
  }
  let expected : Json = [
    {
      "path": "$.args.amount",
      "keyword": "minimum",
      "message": "expected number >= 0",
    },
  ]
  assert_eq(validation_json(value, schema), expected)
}

///|
test "schema maximum catches a fractional excess" {
  assert_eq(validation_locations(2.51, { "maximum": 2.5 }), [("$", "maximum")])
}

///|
test "schema numeric bounds distinguish wide integer source literals" {
  let value = Json::number(9007199254740992.0, repr="9007199254740993")
  assert_eq(validation_locations(value, { "maximum": 9007199254740992.0 }), [
    ("$", "maximum"),
  ])
}

///|
test "schema numeric bounds maintain ordering of negative rounded literals" {
  let value = Json::number(-9007199254740992.0, repr="-9007199254740993")
  assert_eq(validation_locations(value, { "minimum": -9007199254740992.0 }), [
    ("$", "minimum"),
  ])
}

///|
test "schema compares rounded decimals with different significand lengths" {
  let lower = Json::number(1.0, repr="1.000000000000000011")
  let upper = Json::number(1.0, repr="1.00000000000000002")
  assert_eq(validation_locations(upper, { "maximum": lower }), [
    ("$", "maximum"),
  ])
}

///|
test "schema enum distinguishes nested rounded integer literals" {
  let value = Json::number(9007199254740992.0, repr="9007199254740993")
  let instance : Json = [value]
  let schema : Json = { "enum": [[9007199254740992.0]] }
  assert_eq(validation_locations(instance, schema), [("$", "enum")])
}

///|
test "schema enum equates different decimal spellings" {
  let value = Json::number(120.0, repr="1.200e+2")
  assert_true(@json_repair.validate(value, { "enum": [120] }).is_empty())
}

///|
test "schema numbers compare exponents beyond the Double range" {
  let lower = Json::number(1.0e308 * 10.0, repr="1e1000000000000000000005")
  let upper = Json::number(1.0e308 * 10.0, repr="1e1000000000000000000006")
  assert_eq(validation_locations(upper, { "maximum": lower }), [
    ("$", "maximum"),
  ])
}

///|
test "schema numbers distinguish negative underflow from zero" {
  let value = Json::number(0.0, repr="-1e-400")
  assert_eq(validation_locations(value, { "minimum": 0 }), [("$", "minimum")])
}

///|
test "schema applies a decimal carry to an extremely long exponent" {
  let nines = "9".repeat(30_000)
  let power_of_ten = "1" + "0".repeat(30_000)
  let infinity = 1.0e308 * 10.0
  let value = Json::number(infinity, repr="2e\{nines}")
  let same = Json::number(infinity, repr="0.2e\{power_of_ten}")
  let lower = Json::number(infinity, repr="0.2e\{nines}")
  assert_true(@json_repair.validate(value, { "enum": [same] }).is_empty())
  assert_eq(validation_locations(value, { "maximum": lower }), [
    ("$", "maximum"),
  ])
}

///|
test "schema applies a decimal borrow to an extremely long negative exponent" {
  let nines = "9".repeat(30_000)
  let power_of_ten = "1" + "0".repeat(30_000)
  let value = Json::number(0.0, repr="2e-\{power_of_ten}")
  let same = Json::number(0.0, repr="0.2e-\{nines}")
  let lower = Json::number(0.0, repr="0.2e-\{power_of_ten}")
  assert_true(@json_repair.validate(value, { "enum": [same] }).is_empty())
  assert_eq(validation_locations(value, { "maximum": lower }), [
    ("$", "maximum"),
  ])
}

///|
test "schema normalizes an exponent across the signed integer fast path" {
  let infinity = 1.0e308 * 10.0
  let left = Json::number(infinity, repr="2e999999999999999999")
  let right = Json::number(infinity, repr="0.2e+001000000000000000000")
  assert_true(@json_repair.validate(left, { "enum": [right] }).is_empty())
  let finite = Json::number(0.123, repr="12.3e-00000002")
  assert_true(@json_repair.validate(finite, { "enum": [0.123] }).is_empty())
}

///|
test "schema minLength counts Unicode code points" {
  assert_eq(validation_locations("风🌠", { "minLength": 3 }), [
    ("$", "minLength"),
  ])
}

///|
test "schema maxLength counts an emoji once" {
  assert_true(@json_repair.validate("🌠", { "maxLength": 1 }).is_empty())
}

///|
test "schema maxLength counts combining marks separately" {
  assert_eq(validation_locations("e\u0301", { "maxLength": 1 }), [
    ("$", "maxLength"),
  ])
}

///|
test "schema allows length exactly zero" {
  assert_true(
    @json_repair.validate("", { "minLength": 0, "maxLength": 0 }).is_empty(),
  )
  assert_eq(validation_locations("x", { "maxLength": 0 }), [("$", "maxLength")])
}

///|
test "schema items reports every invalid array element" {
  assert_eq(
    validation_locations([1, "x", 3, false], { "items": { "type": "integer" } }),
    [("$[1]", "type"), ("$[3]", "type")],
  )
}

///|
test "schema items follows nested objects and array indices" {
  let value : Json = { "args": [{ "amount": 1 }, { "amount": -1 }] }
  let schema : Json = {
    "properties": {
      "args": { "items": { "properties": { "amount": { "minimum": 0 } } } },
    },
  }
  assert_eq(validation_locations(value, schema), [
    ("$.args[1].amount", "minimum"),
  ])
}

///|
test "schema paths escape ambiguous property names" {
  let schema : Json = {
    "properties": { "a.b": { "required": ["q\"uote", "", "9key", "中"] } },
  }
  assert_eq(validation_locations({ "a.b": Json::empty_object() }, schema), [
    ("$[\"a.b\"][\"q\\\"uote\"]", "required"),
    ("$[\"a.b\"][\"\"]", "required"),
    ("$[\"a.b\"][\"9key\"]", "required"),
    ("$[\"a.b\"][\"中\"]", "required"),
  ])
}

///|
test "schema items accepts empty arrays under a false subschema" {
  assert_true(@json_repair.validate([], { "items": false }).is_empty())
  assert_eq(validation_locations([0], { "items": false }), [("$[0]", "false")])
}

///|
test "schema rejects malformed top-level definitions" {
  assert_eq(validation_locations(1, []), [("$schema", "schema")])
}

///|
test "schema checks optional property definitions before instance traversal" {
  let schema : Json = { "properties": { "absent": { "type": "numeric" } } }
  assert_eq(validation_locations(Json::empty_object(), schema), [
    ("$schema.properties.absent.type", "type"),
  ])
}

///|
test "schema checks items definitions even on empty arrays" {
  assert_eq(validation_locations([], { "items": 12 }), [
    ("$schema.items", "schema"),
  ])
}

///|
test "schema requires nonempty enum and well-formed numeric and length bounds" {
  let schema : Json = {
    "enum": [],
    "minimum": "0",
    "minLength": 1.5,
    "maxLength": -1,
  }
  assert_eq(validation_locations("", schema), [
    ("$schema.enum", "enum"),
    ("$schema.maxLength", "maxLength"),
    ("$schema.minLength", "minLength"),
    ("$schema.minimum", "minimum"),
  ])
}

///|
test "schema rejects duplicate required names and non-string entries" {
  assert_eq(
    validation_locations(Json::empty_object(), {
      "required": ["name", "name", 0],
    }),
    [("$schema.required[1]", "required"), ("$schema.required[2]", "required")],
  )
}

///|
test "schema rejects unsupported constraints without rejecting metadata" {
  let schema : Json = {
    "title": "Contact",
    "$id": "contact",
    "pattern": "^[A-Z]",
  }
  assert_eq(validation_locations("abc", schema), [
    ("$schema.pattern", "pattern"),
  ])
}

///|
test "schema rejects duplicate and invalid type union members" {
  let schema : Json = { "type": ["string", "string", "date", 0] }
  assert_eq(validation_locations("", schema), [
    ("$schema.type[1]", "type"),
    ("$schema.type[2]", "type"),
    ("$schema.type[3]", "type"),
  ])
}

///|
test "schema checks the shape of properties definitions" {
  assert_eq(
    validation_locations(Json::empty_object(), { "properties": ["a"] }),
    [("$schema.properties", "properties")],
  )
}

///|
test "schema checks precise decimal bounds on a repaired tool-call" {
  let schema = @json.parse(
    "{\"properties\":{\"amount\":{\"maximum\":1.000000000000000011}}}",
    preserve_number_repr=true,
  )
  match @json_repair.repair("{amount: 1.00000000000000002") {
    Ok(report) =>
      assert_eq(validation_locations(report.value, schema), [
        ("$.amount", "maximum"),
      ])
    Err(error) => fail(error.message)
  }
}
