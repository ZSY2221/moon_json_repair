///|
/// An RFC 6902 add, replace, or remove operation. The empty path points to
/// the entire document. An explicit JSON null is distinct from an absent value.
#derive(Eq, Debug)
pub(all) struct JsonPatch {
  op : String
  path : String
  value : Json?
}

///|
/// Serialize the RFC 6902 operation. The value member is present only when
/// the operation carries a value.
pub impl ToJson for JsonPatch with fn to_json(self) {
  let object : Map[String, Json] = { "op": self.op, "path": self.path }
  if self.value is Some(value) {
    object["value"] = value
  }
  Json::object(object)
}

///|
/// Snapshot of a JSON Pointer's source closure. Synthetic quotes and container
/// delimiters keep a value streaming, even after the transport has finished.
#derive(Eq, Debug)
pub(all) struct FieldSeal {
  pointer : String
  is_sealed : Bool
}

///|
/// Serialize the RFC 6901 pointer and its source-closure flag as sealed.
pub impl ToJson for FieldSeal with fn to_json(self) {
  { "pointer": self.pointer, "sealed": self.is_sealed }
}

///|
priv struct SealTrace {
  mut path : String
  fields : Array[FieldSeal]
}

///|
/// Operations and closure state for a successfully repaired stream prefix.
/// Apply the first frame to JSON null and subsequent frames in delivery order.
#derive(Eq, Debug, ToJson)
pub(all) struct PatchFrame {
  patches : Array[JsonPatch]
  fields : Array[FieldSeal]
  report : RepairReport
}

///|
fn pointer_child(path : String, key : String) -> String {
  path + "/" + key.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
}

///|
fn exact_patch_scalar(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Number(a, repr=ra), Number(b, repr=rb)) =>
      ra.unwrap_or_else(() => a.to_string()) ==
      rb.unwrap_or_else(() => b.to_string())
    (String(a), String(b)) => a == b
    (True, True) | (False, False) | (Null, Null) => true
    _ => false
  }
}

///|
fn patch_value_equal(a : Json, b : Json, depth : Int32) -> Bool {
  if depth > 256 {
    return false
  }
  match (a, b) {
    (Array(a), Array(b)) => {
      if a.length() != b.length() {
        return false
      }
      for index, value in a {
        if !patch_value_equal(value, b[index], depth + 1) {
          return false
        }
      }
      true
    }
    (Object(a), Object(b)) => {
      if a.length() != b.length() {
        return false
      }
      for key, value in a {
        guard b.get(key) is Some(other) else { return false }
        if !patch_value_equal(value, other, depth + 1) {
          return false
        }
      }
      true
    }
    _ => exact_patch_scalar(a, b)
  }
}

///|
fn clone_patch_value(value : Json) -> Json {
  match value {
    Array(items) => Json::array(items.map(clone_patch_value))
    Object(object) => {
      let copy = object.copy()
      for key, item in object {
        copy[key] = clone_patch_value(item)
      }
      Json::object(copy)
    }
    _ => value
  }
}

///|
// Align a bounded pair of changing array middles. Streaming appends and
// suffix edits have an empty or single-cell side and take the direct path.
fn align_patch_array(
  before : ArrayView[Json],
  after : ArrayView[Json],
  path : String,
  offset : Int32,
  depth : Int32,
  patches : Array[JsonPatch],
) -> Unit {
  let old_length = before.length()
  let new_length = after.length()
  let row = new_length + 1
  let cost = FixedArray::make((old_length + 1) * row, 0)
  for i = old_length; i >= 0; i = i - 1 {
    for j = new_length; j >= 0; j = j - 1 {
      let at = i * row + j
      cost[at] = if i == old_length {
        new_length - j
      } else if j == new_length {
        old_length - i
      } else {
        let edit = if patch_value_equal(before[i], after[j], depth) {
          0
        } else {
          1
        }
        (cost[at + row + 1] + edit).min(cost[at + row].min(cost[at + 1]) + 1)
      }
    }
  }
  let mut i = 0
  let mut j = 0
  let mut index = offset
  while i < old_length || j < new_length {
    let at = i * row + j
    if i < old_length &&
      j < new_length &&
      patch_value_equal(before[i], after[j], depth) {
      i += 1
      j += 1
      index += 1
    } else if i < old_length &&
      j < new_length &&
      cost[at] == cost[at + row + 1] + 1 {
      patch_diff(before[i], after[j], "\{path}/\{index}", depth, patches)
      i += 1
      j += 1
      index += 1
    } else if i < old_length && cost[at] == cost[at + row] + 1 {
      patches.push({ op: "remove", path: "\{path}/\{index}", value: None, })
      i += 1
    } else {
      patches.push({
        op: "add",
        path: "\{path}/\{index}",
        value: Some(after[j]),
      })
      j += 1
      index += 1
    }
  }
}

///|
fn patch_array(
  before : Array[Json],
  after : Array[Json],
  path : String,
  depth : Int32,
  patches : Array[JsonPatch],
) -> Unit {
  let mut first = 0
  let mut last_before = before.length()
  let mut last_after = after.length()
  while first < last_before &&
        first < last_after &&
        patch_value_equal(before[first], after[first], depth) {
    first += 1
  }
  while last_before > first &&
        last_after > first &&
        patch_value_equal(before[last_before - 1], after[last_after - 1], depth) {
    last_before -= 1
    last_after -= 1
  }
  let old_middle = last_before - first
  let new_middle = last_after - first
  if old_middle > 1 && new_middle > 1 && old_middle <= 4096 / new_middle {
    align_patch_array(
      before[first:last_before],
      after[first:last_after],
      path,
      first,
      depth,
      patches,
    )
    return
  }
  let shared = if last_before < last_after { last_before } else { last_after }
  for index in first..<shared {
    patch_diff(before[index], after[index], "\{path}/\{index}", depth, patches)
  }
  // Remove in descending order so a later positional removal never shifts.
  for index = last_before - 1; index >= shared; index = index - 1 {
    patches.push({ op: "remove", path: "\{path}/\{index}", value: None, })
  }
  for index in shared..<last_after {
    patches.push({
      op: "add",
      path: "\{path}/\{index}",
      value: Some(after[index]),
    })
  }
}

///|
fn patch_diff(
  before : Json,
  after : Json,
  path : String,
  depth : Int32,
  patches : Array[JsonPatch],
) -> Unit {
  if depth > 256 {
    patches.push({ op: "replace", path, value: Some(after), })
    return
  }
  match (before, after) {
    (Object(before), Object(after)) => {
      for key, value in before {
        match after.get(key) {
          Some(next) =>
            patch_diff(
              value,
              next,
              pointer_child(path, key),
              depth + 1,
              patches,
            )
          None =>
            patches.push({
              op: "remove",
              path: pointer_child(path, key),
              value: None,
            })
        }
      }
      for key, value in after {
        if !before.contains(key) {
          patches.push({
            op: "add",
            path: pointer_child(path, key),
            value: Some(value),
          })
        }
      }
    }
    (Array(before), Array(after)) =>
      patch_array(before, after, path, depth + 1, patches)
    _ =>
      if !exact_patch_scalar(before, after) {
        patches.push({ op: "replace", path, value: Some(after), })
      }
  }
}

///|
/// Generate deterministic structural changes, keeping unchanged branches and
/// common array edges intact. Short changed array runs use edit-distance
/// alignment. Large runs use bounded-memory positional edits. Numbers compare
/// their lossless decimal spelling.
///
/// ```mbt check
/// test {
///   let previous : Json = { "queue": [1] }
///   let current : Json = { "queue": [1, 2] }
///   let patches = @json_repair.diff_json_patches(previous, current)
///   assert_eq(patches[0].path, "/queue/1")
///   assert_eq(
///     @json_repair.apply_json_patches(previous, patches[:]).unwrap(),
///     current,
///   )
/// }
/// ```
pub fn diff_json_patches(previous : Json, next : Json) -> Array[JsonPatch] {
  let patches = []
  patch_diff(previous, next, "", 0, patches)
  patches
}

///|
priv suberror PatchFault {
  BadPatch(String)
}

///|
fn decode_pointer_token(token : StringView) -> String raise PatchFault {
  if !token.contains("~") {
    return token.to_owned()
  }
  let text = StringBuilder()
  let mut start = 0
  let mut index = 0
  while index < token.length() {
    if token[index] != '~' {
      index += 1
      continue
    }
    text.write_view(token.exact_view(start~, end=index))
    let decoded = match char_at(token, index + 1) {
      '0' => '~'
      '1' => '/'
      _ => raise BadPatch("invalid JSON Pointer escape")
    }
    text.write_char(decoded)
    index += 2
    start = index
  }
  text.write_view(token.exact_view(start~))
  text.to_string()
}

///|
fn pointer_tokens(path : String) -> Array[String] raise PatchFault {
  if path == "" {
    return []
  }
  guard path.has_prefix("/") else {
    raise BadPatch("JSON Pointer must start with /")
  }
  let tokens = []
  for token in path[:].exact_view(start=1).split("/") {
    if tokens.length() > 256 {
      raise BadPatch("JSON Pointer exceeds the depth limit")
    }
    tokens.push(decode_pointer_token(token))
  }
  tokens
}

///|
fn pointer_array_index(
  token : String,
  length : Int32,
  insert : Bool,
) -> Int32 raise PatchFault {
  if token == "-" && insert {
    return length
  }
  if token.is_empty() || (token.length() > 1 && token.has_prefix("0")) {
    raise BadPatch("invalid JSON Pointer array index")
  }
  let mut index = 0
  let limit = if insert { length } else { length - 1 }
  for i in 0..<token.length() {
    let digit = token[i].to_int() - '0'.to_int()
    if digit < 0 || digit > 9 || digit > limit || index > (limit - digit) / 10 {
      raise BadPatch("invalid or out-of-range JSON Pointer array index")
    }
    index = index * 10 + digit
  }
  index
}

///|
fn patch_value(patch : JsonPatch) -> Json raise PatchFault {
  guard patch.value is Some(value) else {
    raise BadPatch("patch operation requires a value")
  }
  value
}

///|
fn apply_patch_at(
  node : Json,
  tokens : ArrayView[String],
  patch : JsonPatch,
) -> Json raise PatchFault {
  guard tokens is [token, .. rest] else {
    if patch.op == "remove" {
      raise BadPatch("removing the document root leaves no JSON value")
    }
    return patch_value(patch)
  }
  match node {
    Object(object) => {
      let copy = object.copy()
      if rest.length() == 0 && patch.op == "add" {
        copy[token] = patch_value(patch)
      } else {
        guard object.get(token) is Some(previous) else {
          raise BadPatch("JSON Pointer does not refer to an existing member")
        }
        if rest.length() == 0 && patch.op == "remove" {
          copy.remove(token)
        } else {
          copy[token] = apply_patch_at(previous, rest, patch)
        }
      }
      Json::object(copy)
    }
    Array(array) => {
      let insert = rest.length() == 0 && patch.op == "add"
      let index = pointer_array_index(token, array.length(), insert)
      let copy = array.copy()
      if insert {
        copy.insert(index, patch_value(patch))
      } else if rest.length() == 0 && patch.op == "remove" {
        ignore(copy.remove(index))
      } else {
        copy[index] = apply_patch_at(array[index], rest, patch)
      }
      Json::array(copy)
    }
    _ => raise BadPatch("JSON Pointer traverses a non-container value")
  }
}

///|
/// Apply add, replace, and remove transactionally, without mutating the input.
/// Root remove is rejected because the result type requires a JSON document.
pub fn apply_json_patches(
  input : Json,
  patches : ArrayView[JsonPatch],
) -> Result[Json, String] {
  let mut current = input
  for index, patch in patches {
    if !(patch.op is ("add" | "replace" | "remove")) {
      return Err("operation \{index}: unsupported patch operation")
    }
    current = try {
      let tokens = pointer_tokens(patch.path)
      apply_patch_at(current, tokens[:], patch)
    } catch {
      BadPatch(message) => return Err("operation \{index}: " + message)
    }
  }
  Ok(current)
}
