///|
/// Explicit capabilities for semantic schema coercion. Construct these options
/// from legacy options with [CoercionOptions::with_semantic]. Padding removal
/// applies only to enum, numeric, and boolean tokens, using JSON whitespace.
/// Scalar wrapping uses a single array layer and requires a valid result.
#derive(Eq, Debug)
pub(all) struct SemanticCoercionOptions {
  base : CoercionOptions
  fuzzy_keys : Bool
  enum_case : Bool
  trim_padding : Bool
  wrap_singletons : Bool
}

///|
/// Opt into unique key recovery, ASCII enum case matching, removal of
/// surrounding JSON whitespace from typed tokens, and single-element arrays.
/// The original type coercion flags are carried through unchanged.
pub fn CoercionOptions::with_semantic(
  self : CoercionOptions,
) -> SemanticCoercionOptions {
  {
    base: self,
    fuzzy_keys: true,
    enum_case: true,
    trim_padding: true,
    wrap_singletons: true,
  }
}

///|
/// Try explicitly enabled semantic repairs and then validate the result.
/// Fuzzy key recovery is restricted to ASCII alphanumeric/underscore keys
/// of up to 64 units in objects and schemas of up to 128 entries. A
/// case/underscore match outranks edit distance. One edit is allowed on short
/// normalized keys and two when both have at least eight units. Equal best
/// candidates, occupied destinations, and competing claims stay untouched and
/// appear as errors. Check [CoercionReport::errors] before using the output.
pub fn coerce_with_schema_semantic(
  value : JsonValue,
  schema : JsonValue,
  options~ : SemanticCoercionOptions = CoercionOptions::default().with_semantic(),
) -> CoercionReport {
  coerce_report(value, schema, options.base, semantic=Some(options))
}

///|
priv struct SemanticContext {
  options : SemanticCoercionOptions
  errors : Array[ValidationError]
}

///|
let semantic_json_padding : String = " \t\r\n"

///|
fn normalize_enum(
  text : String,
  schema : Json,
  rules : Map[String, Json],
  options : SemanticCoercionOptions,
) -> Json? {
  guard (options.enum_case || options.trim_padding) &&
    rules.get("enum") is Some(Array(choices)) else {
    return None
  }
  let value = Json::string(text)
  if choices.any(choice => choice == value) {
    return None
  }
  let untrimmed = text[:]
  let actual = untrimmed.trim(chars=semantic_json_padding)
  let mut found : String? = None
  for choice in choices {
    guard choice is String(candidate) else { continue }
    // Match against the precise declared spelling. Case-only and trimmed
    // interpretations compete, so distinct matches still count as ambiguous.
    let matches = if options.enum_case {
      untrimmed.equal_ignore_ascii_case(candidate[:]) ||
      (options.trim_padding && actual.equal_ignore_ascii_case(candidate[:]))
    } else {
      actual == candidate[:]
    }
    if matches {
      if found is Some(previous) && previous != candidate {
        return None
      }
      found = Some(candidate)
    }
  }
  guard found is Some(canonical) else { return None }
  let after = Json::string(canonical)
  if node_is_valid(after, schema) {
    Some(after)
  } else {
    None
  }
}

///|
fn trim_scalar(
  text : String,
  target : String?,
  schema : Json,
  path : String,
  options : CoercionOptions,
  edits : Array[CoercionEdit],
) -> Json? {
  guard target is Some("number" | "integer" | "boolean") else { return None }
  let trimmed = text[:].trim(chars=semantic_json_padding)
  guard trimmed.length() != text.length() else { return None }
  let token = Json::string(trimmed.to_owned())
  guard coerce_atom(token, target, options) is Some((kind, after)) &&
    node_is_valid(after, schema) else {
    return None
  }
  edits.push({
    path,
    kind: "trim_scalar_padding",
    before: Json::string(text),
    after: token,
  })
  edits.push({ path, kind, before: token, after, })
  Some(after)
}

///|
fn key_spelling(text : String) -> String? {
  guard text.length() <= 64 else { return None }
  let out = StringBuilder()
  for char in text {
    if char.is_ascii_alphabetic() || char.is_ascii_digit() {
      out.write_char(char.to_ascii_lowercase())
    } else if char != '_' {
      return None
    }
  }
  let spelling = out.to_string()
  if spelling.is_empty() {
    None
  } else {
    Some(spelling)
  }
}

///|
// Strip a common prefix, making substitutions/deletions/insertions branch
// only at mismatches. The explicit budget caps recursion at two edits.
fn key_distance(left : StringView, right : StringView, budget : Int32) -> Int32 {
  let difference = (left.length() - right.length()).abs()
  let rejected = budget + 1
  if difference > budget {
    return rejected
  }
  let mut common = 0
  let shared = left.length().min(right.length())
  while common < shared && left[common] == right[common] {
    common += 1
  }
  if common == shared {
    return difference
  }
  if budget == 0 {
    return rejected
  }
  let left_tail = left.exact_view(start=common + 1, end=left.length())
  let right_tail = right.exact_view(start=common + 1, end=right.length())
  let sub = key_distance(left_tail, right_tail, budget - 1)
  let del = key_distance(
    left_tail,
    right.exact_view(start=common, end=right.length()),
    budget - 1,
  )
  let add = key_distance(
    left.exact_view(start=common, end=left.length()),
    right_tail,
    budget - 1,
  )
  1 + sub.min(del).min(add)
}

///|
fn best_keys(
  spelling : String,
  candidates : Array[(String, String)],
) -> Array[String] {
  let best = []
  let mut score = 3
  for candidate in candidates {
    let (name, other) = candidate
    let budget = if spelling.length().min(other.length()) >= 8 { 2 } else { 1 }
    let distance = key_distance(spelling[:], other[:], budget)
    if distance <= budget {
      if distance < score {
        best.clear()
        score = distance
      }
      if distance == score {
        best.push(name)
      }
    }
  }
  best
}

///|
fn recover_keys(
  fields : Map[String, Json],
  properties : Map[String, Json],
  names : Array[String],
  path : String,
  errors : Array[ValidationError],
  edits : Array[CoercionEdit],
) -> Map[String, Json]? {
  guard !properties.is_empty() &&
    fields.length() <= 128 &&
    properties.length() <= 128 else {
    return None
  }
  let sources = fields
    .keys()
    .filter(name => !properties.contains(name))
    .collect()
  guard !sources.is_empty() else { return None }
  sources.sort_by(String::lexical_compare)
  let candidates : Array[(String, String)] = []
  for name in names {
    if !(properties[name] is False) && key_spelling(name) is Some(canonical) {
      candidates.push((name, canonical))
    }
  }
  let resolutions : Map[String, Array[String]] = Map([])
  let claims : Map[String, Int32] = Map([])
  for source in sources {
    if key_spelling(source) is Some(spelling) {
      let best = best_keys(spelling, candidates)
      resolutions[source] = best
      // Every equally close target is contested, including targets beyond
      // the two names displayed in the ambiguity diagnostic.
      for target in best {
        claims[target] = claims.get(target).unwrap_or(0) + 1
      }
    }
  }
  let mut updated = None
  for source in sources {
    match resolutions.get(source) {
      Some([first, second, ..]) =>
        errors.push({
          path: schema_key_path(path, source),
          keyword: "ambiguous_key",
          message: "key matches multiple properties equally, including \{first} and \{second}",
        })
      Some([target]) =>
        if fields.contains(target) || claims[target] > 1 {
          errors.push({
            path: schema_key_path(path, source),
            keyword: "key_collision",
            message: "key would overwrite or compete for \{schema_key_path(path, target)}",
          })
        } else {
          let copy = updated.unwrap_or_else(() => fields.copy())
          copy.remove(source)
          copy[target] = fields[source]
          updated = Some(copy)
          edits.push({
            path: schema_key_path(path, target),
            kind: "rename_key",
            before: Json::string(source),
            after: Json::string(target),
          })
        }
      _ => ()
    }
  }
  updated
}
