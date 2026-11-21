///|
/// A failed constraint. Instance paths start at `$` and definition paths at
/// `$schema`. Array indices are zero-based and unusual keys are JSON-quoted.
#derive(Eq, Debug)
pub struct ValidationError {
  path : String
  keyword : String
  message : String
}

///|
/// Serialize the location and keyword with the human-readable diagnostic.
pub impl ToJson for ValidationError with fn to_json(self) {
  { "path": self.path, "keyword": self.keyword, "message": self.message }
}

///|
/// Expose `ValidationError` serialization through the direct `to_json` method.
pub extend ValidationError with ToJson::{to_json}

///|
let schema_depth_limit : Int32 = 256

///|
/// Validate a JSON value against the tool-call schema subset. Definitions
/// support `type`, `required`, `properties`, `enum`, `minimum`, `maximum`,
/// `minLength`, `maxLength`, and `items`, plus boolean schemas.
/// Definition errors take precedence even when the instance would skip a rule.
pub fn validate(
  value : JsonValue,
  schema : JsonValue,
) -> Array[ValidationError] {
  let errors = []
  check_schema(schema, "$schema", 0, errors)
  if errors.is_empty() {
    validate_node(value, schema, "$", (error, _, _) => errors.push(error))
  }
  errors
}

///|
fn schema_key_path(path : String, key : String) -> String {
  let mut identifier = !key.is_empty()
  for index, char in key.iter2() {
    if !(char.is_ascii_alphabetic() ||
      char == '_' ||
      (index > 0 && char.is_ascii_digit())) {
      identifier = false
      break
    }
  }
  if identifier {
    "\{path}.\{key}"
  } else {
    "\{path}[\{Json::string(key).stringify()}]"
  }
}

///|
fn known_schema_type(name : String) -> Bool {
  match name {
    "array" | "boolean" | "integer" | "null" | "number" | "object" | "string" =>
      true
    _ => false
  }
}

///|
fn check_string_set(
  value : Json,
  path : String,
  keyword : String,
  type_names : Bool,
  errors : Array[ValidationError],
) -> Unit {
  if value is Array(entries) {
    if type_names && entries.is_empty() {
      errors.push({ path, keyword, message: "expected at least one type name", })
    }
    let seen : Map[String, Unit] = Map([])
    for index, entry in entries {
      let item_path = "\{path}[\{index}]"
      match entry {
        String(name) =>
          if type_names && !known_schema_type(name) {
            errors.push({
              path: item_path,
              keyword,
              message: "unknown type \{name}",
            })
          } else if seen.contains(name) {
            errors.push({
              path: item_path,
              keyword,
              message: "duplicate entry",
            })
          } else {
            seen[name] = ()
          }
        _ =>
          errors.push({ path: item_path, keyword, message: "expected string", })
      }
    }
  } else {
    errors.push({ path, keyword, message: "expected array of strings", })
  }
}

///|
fn check_schema(
  schema : Json,
  path : String,
  depth : Int32,
  errors : Array[ValidationError],
) -> Unit {
  if depth > schema_depth_limit {
    errors.push({
      path,
      keyword: "depth",
      message: "schema nesting limit exceeded",
    })
    return
  }
  match schema {
    True | False => ()
    Object(rules) => {
      let keys = rules.keys().collect()
      keys.sort_by(String::lexical_compare)
      for keyword in keys {
        let rule = rules[keyword]
        let rule_path = schema_key_path(path, keyword)
        match keyword {
          "type" =>
            match rule {
              String(name) =>
                if !known_schema_type(name) {
                  errors.push({
                    path: rule_path,
                    keyword,
                    message: "unknown type \{name}",
                  })
                }
              _ => check_string_set(rule, rule_path, keyword, true, errors)
            }
          "required" =>
            check_string_set(rule, rule_path, keyword, false, errors)
          "properties" =>
            if rule is Object(properties) {
              let names = properties.keys().collect()
              names.sort_by(String::lexical_compare)
              for name in names {
                check_schema(
                  properties[name],
                  schema_key_path(rule_path, name),
                  depth + 1,
                  errors,
                )
              }
            } else {
              errors.push({
                path: rule_path,
                keyword,
                message: "expected object of property schemas",
              })
            }
          "items" => check_schema(rule, rule_path, depth + 1, errors)
          "enum" =>
            if !(rule is Array(values) && !values.is_empty()) {
              errors.push({
                path: rule_path,
                keyword,
                message: "expected nonempty array",
              })
            }
          "minimum" | "maximum" =>
            if !schema_matches_type(rule, "number") {
              errors.push({
                path: rule_path,
                keyword,
                message: "expected number",
              })
            }
          "minLength" | "maxLength" =>
            if !(schema_matches_type(rule, "integer") &&
              compare_schema_numbers(rule, Json::number(0.0)) >= 0) {
              errors.push({
                path: rule_path,
                keyword,
                message: "expected nonnegative integer",
              })
            }
          "$schema"
          | "$id"
          | "$comment"
          | "title"
          | "description"
          | "default"
          | "examples"
          | "readOnly"
          | "writeOnly"
          | "deprecated" => ()
          _ =>
            errors.push({
              path: rule_path,
              keyword,
              message: "unsupported keyword",
            })
        }
      }
    }
    _ =>
      errors.push({
        path,
        keyword: "schema",
        message: "expected object or boolean schema",
      })
  }
}

///|
fn schema_matches_type(value : Json, name : String) -> Bool {
  match (value, name) {
    (Null, "null")
    | (True | False, "boolean")
    | (String(_), "string")
    | (Array(_), "array")
    | (Object(_), "object") => true
    (Number(number, repr~), "number") =>
      number.is_finite() || (number.is_inf() && repr is Some(_))
    (Number(number, repr~), "integer") =>
      match repr {
        Some(text) =>
          match decimal_parts(text) {
            Some(parts) =>
              parts.sign == 0 ||
              compare_decimal_ranks(
                parts.rank,
                decimal_rank(parts.digits.length().to_int64()),
              ) >=
              0
            None => false
          }
        None => number.is_finite() && number.floor() == number
      }
    _ => false
  }
}

///|
fn validate_node(
  value : Json,
  schema : Json,
  path : String,
  emit : (ValidationError, Json?, Json) -> Unit,
) -> Unit {
  if schema is Object(rules) {
    match rules.get("type") {
      Some(String(name)) =>
        if !schema_matches_type(value, name) {
          emit(
            { path, keyword: "type", message: "expected \{name}", },
            Some(value),
            schema,
          )
        }
      Some(Array(types)) =>
        if !types.any(entry => {
            entry is String(name) && schema_matches_type(value, name)
          }) {
          let expected = Json::array(types).stringify()
          emit(
            { path, keyword: "type", message: "expected one of \{expected}", },
            Some(value),
            schema,
          )
        }
      _ => ()
    }
    if rules.get("enum") is Some(Array(choices)) &&
      !choices.any(choice => schema_enum_equal(value, choice, 0)) {
      emit(
        { path, keyword: "enum", message: "expected a value from enum", },
        Some(value),
        schema,
      )
    }
    match value {
      Number(_, ..) => {
        if rules.get("minimum") is Some(minimum) &&
          compare_schema_numbers(value, minimum) < 0 {
          emit(
            {
              path,
              keyword: "minimum",
              message: "expected number >= \{minimum.stringify()}",
            },
            Some(value),
            schema,
          )
        }
        if rules.get("maximum") is Some(maximum) &&
          compare_schema_numbers(value, maximum) > 0 {
          emit(
            {
              path,
              keyword: "maximum",
              message: "expected number <= \{maximum.stringify()}",
            },
            Some(value),
            schema,
          )
        }
      }
      String(text) => {
        let minimum = rules.get("minLength")
        let maximum = rules.get("maxLength")
        if minimum is Some(_) || maximum is Some(_) {
          let length = Json::number(text.iter().count().to_double())
          if minimum is Some(bound) && compare_schema_numbers(length, bound) < 0 {
            emit(
              {
                path,
                keyword: "minLength",
                message: "expected at least \{bound.stringify()} Unicode code points",
              },
              Some(value),
              schema,
            )
          }
          if maximum is Some(bound) && compare_schema_numbers(length, bound) > 0 {
            emit(
              {
                path,
                keyword: "maxLength",
                message: "expected at most \{bound.stringify()} Unicode code points",
              },
              Some(value),
              schema,
            )
          }
        }
      }
      Object(fields) => {
        if rules.get("required") is Some(Array(required)) {
          for field in required {
            if field is String(name) && !fields.contains(name) {
              let child_schema = if rules.get("properties")
                is Some(Object(properties)) {
                properties.get(name).unwrap_or(Json::boolean(true))
              } else {
                Json::boolean(true)
              }
              emit(
                {
                  path: schema_key_path(path, name),
                  keyword: "required",
                  message: "required property is missing",
                },
                None,
                child_schema,
              )
            }
          }
        }
        if rules.get("properties") is Some(Object(properties)) {
          let names = properties.keys().collect()
          names.sort_by(String::lexical_compare)
          for name in names {
            if fields.get(name) is Some(child) {
              validate_node(
                child,
                properties[name],
                schema_key_path(path, name),
                emit,
              )
            }
          }
        }
      }
      Array(items) =>
        if rules.get("items") is Some(item_schema) {
          for index, item in items {
            validate_node(item, item_schema, "\{path}[\{index}]", emit)
          }
        }
      _ => ()
    }
  } else if schema is False {
    emit(
      { path, keyword: "false", message: "rejected by false schema", },
      Some(value),
      schema,
    )
  }
}

///|
fn schema_enum_equal(left : Json, right : Json, depth : Int32) -> Bool {
  if depth > schema_depth_limit {
    return false
  }
  match (left, right) {
    (Number(a, ..), Number(b, ..)) =>
      !a.is_nan() && !b.is_nan() && compare_schema_numbers(left, right) == 0
    (Array(a), Array(b)) => {
      if a.length() != b.length() {
        return false
      }
      for index, item in a {
        if !schema_enum_equal(item, b[index], depth + 1) {
          return false
        }
      }
      true
    }
    (Object(a), Object(b)) => {
      if a.length() != b.length() {
        return false
      }
      for key, item in a {
        guard b.get(key) is Some(other) else { return false }
        if !schema_enum_equal(item, other, depth + 1) {
          return false
        }
      }
      true
    }
    (Null, Null) | (True, True) | (False, False) => true
    (String(a), String(b)) => a == b
    _ => false
  }
}

///|
/// For nonzero numbers, the first digit has weight 10^(rank - 1).
/// Keeping the rank separate avoids materializing zeros from large exponents.
priv struct DecimalParts {
  sign : Int32
  digits : StringView
  rank : DecimalRank
}

///|
priv struct DecimalRank {
  sign : Int32
  digits : StringView
}

///|
fn decimal_rank(value : Int64) -> DecimalRank {
  let text = value.to_string()
  if value < 0L {
    { sign: -1, digits: text[1:], }
  } else {
    { sign: value.compare(0L), digits: text[:], }
  }
}

///|
fn compare_decimal_ranks(left : DecimalRank, right : DecimalRank) -> Int32 {
  if left.sign != right.sign {
    return left.sign.compare(right.sign)
  }
  let length_order = left.digits.length().compare(right.digits.length())
  left.sign *
  (if length_order != 0 {
    length_order
  } else {
    left.digits.lexical_compare(right.digits)
  })
}

///|
// Add the finite mantissa offset to an arbitrary-length decimal exponent in
// linear time. The exponent stays in base 10 so it never requires conversion
// to a large binary integer.
fn adjust_exponent(exponent : StringView, offset : Int32) -> DecimalRank? {
  let sign = if exponent.get_char(0) == Some('-') { -1 } else { 1 }
  let digits = match exponent.get_char(0) {
    Some('+' | '-') => exponent[1:]
    _ => exponent
  }
  guard !digits.is_empty() else { return None }
  for unit in digits {
    if unit < '0' || unit > '9' {
      return None
    }
  }
  let digits = digits.trim_start(chars="0")
  if digits.is_empty() {
    return Some(decimal_rank(offset.to_int64()))
  }
  if offset == 0 {
    return Some({ sign, digits, })
  }
  if digits.length() <= 18 {
    let mut value = 0L
    for unit in digits {
      value = value * 10L + (unit.to_int() - '0').to_int64()
    }
    return Some(decimal_rank(value * sign.to_int64() + offset.to_int64()))
  }
  // Beyond 18 digits, an Int32 offset cannot change the exponent's sign.
  let adjusted = Array::make(digits.length() + 1, '0')
  let mut carry = offset.to_int64() * sign.to_int64()
  let mut index = digits.length() - 1
  while index >= 0 {
    let sum = (digits[index].to_int() - '0').to_int64() + carry
    let digit = (sum % 10L + 10L) % 10L
    adjusted[index + 1] = (digit.to_int() + '0').unsafe_to_char()
    carry = (sum - digit) / 10L
    index -= 1
  }
  let start = if carry > 0L {
    adjusted[0] = '1'
    0
  } else if adjusted[1] == '0' {
    2
  } else {
    1
  }
  Some({ sign, digits: String::from_array(adjusted[start:])[:], })
}

///|
fn decimal_parts(text : String) -> DecimalParts? {
  let digits = StringBuilder()
  let mut leading = 0
  let mut fractional = 0
  let mut last_nonzero = 0
  let mut significant = 0
  let mut has_decimal = false
  let mut exp_index = text.length()
  let negative = text.get_char(0) == Some('-')
  for index, char in text.iter2() {
    match char {
      '-' if index == 0 => ()
      '.' if !has_decimal => has_decimal = true
      'e' | 'E' => {
        exp_index = index
        break
      }
      '0'..<='9' => {
        if has_decimal {
          fractional += 1
        }
        if significant == 0 && char == '0' {
          leading += 1
        } else {
          digits.write_char(char)
          significant += 1
          if char != '0' {
            last_nonzero = significant
          }
        }
      }
      _ => return None
    }
  }
  if leading == 0 && significant == 0 {
    return None
  }
  if significant == 0 {
    return Some({ sign: 0, digits: "", rank: decimal_rank(0L), })
  }
  let offset = significant - fractional
  let rank = if exp_index < text.length() {
    guard adjust_exponent(text[exp_index + 1:], offset) is Some(rank) else {
      return None
    }
    rank
  } else {
    decimal_rank(offset.to_int64())
  }
  Some({
    sign: if negative {
      -1
    } else {
      1
    },
    digits: digits.to_string()[:last_nonzero],
    rank,
  })
}

///|
fn compare_schema_numbers(left : Json, right : Json) -> Int32 {
  match (left, right) {
    (Number(a, repr=ra), Number(b, repr=rb)) => {
      if a < b {
        return -1
      }
      if a > b {
        return 1
      }
      if ra is None && rb is None {
        return 0
      }
      // A shared Double can still represent different source decimals.
      let da = decimal_parts(ra.unwrap_or_else(() => a.to_string()))
      let db = decimal_parts(rb.unwrap_or_else(() => b.to_string()))
      guard da is Some(x) && db is Some(y) else { return 0 }
      if x.sign != y.sign {
        return x.sign.compare(y.sign)
      }
      let order = compare_decimal_ranks(x.rank, y.rank)
      if order != 0 {
        return x.sign * order
      }
      // With trailing zeros removed, a prefix sorts before its extension.
      x.sign * x.digits.lexical_compare(y.digits)
    }
    _ => 0
  }
}
