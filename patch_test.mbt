///|
fn strict_patch_json(text : String) -> Json raise {
  @json.parse(text[:], preserve_number_repr=true)
}

///|
fn expect_seal(
  frame : @json_repair.PatchFrame,
  pointer : String,
  expected : Bool,
) -> Unit raise {
  for field in frame.fields {
    if field.pointer == pointer {
      assert_eq(field.is_sealed, expected)
      return
    }
  }
  fail("missing pointer \{pointer}")
}

///|
test "RFC 6902 uses an empty pointer for root replacement" {
  let next : Json = { "x": 1 }
  let patches = @json_repair.diff_json_patches(Json::null(), next)
  assert_eq(
    @json.to_json(patches).stringify(),
    "[{\"op\":\"replace\",\"path\":\"\",\"value\":{\"x\":1}}]",
  )
  assert_eq(
    @json_repair.apply_json_patches(Json::null(), patches[:]).unwrap(),
    next,
  )
}

///|
test "RFC 6901 encodes slash, tilde, and the empty member key independently" {
  let previous : Json = { "": { "a~/b": 1, "~1": 2 } }
  let next : Json = { "": { "a~/b": 2, "~1": 3 } }
  let patches = @json_repair.diff_json_patches(previous, next)
  assert_eq(patches.map(patch => patch.path), ["//a~0~1b", "//~01"])
  assert_eq(
    @json_repair.apply_json_patches(previous, patches[:]).unwrap(),
    next,
  )
}

///|
test "JSON Patch compares adjacent decimal integers beyond JS safe precision" {
  let previous = strict_patch_json("{\"id\":9007199254740992}")
  let next = strict_patch_json("{\"id\":9007199254740993}")
  let patches = @json_repair.diff_json_patches(previous, next)
  assert_eq(patches.length(), 1)
  assert_true(@json.to_json(patches).stringify().contains("9007199254740993"))
  assert_eq(
    @json_repair.apply_json_patches(previous, patches[:]).unwrap().stringify(),
    next.stringify(),
  )
}

///|
test "JSON Patch transports the exact lexeme of scientific notation" {
  let previous = strict_patch_json("1e+3")
  let next = strict_patch_json("1000.00")
  let patches = @json_repair.diff_json_patches(previous, next)
  assert_eq(patches.length(), 1)
  assert_eq(
    @json_repair.apply_json_patches(previous, patches[:]).unwrap().stringify(),
    "1000.00",
  )
}

///|
test "JSON Patch omits remove values and keeps explicit null for add" {
  let previous : Json = { "gone": 1 }
  let next : Json = { "new": Json::null() }
  let patches = @json_repair.diff_json_patches(previous, next)
  assert_eq(
    @json.to_json(patches).stringify(),
    "[{\"op\":\"remove\",\"path\":\"/gone\"},{\"op\":\"add\",\"path\":\"/new\",\"value\":null}]",
  )
  assert_eq(
    @json_repair.apply_json_patches(previous, patches[:]).unwrap(),
    next,
  )
}

///|
test "JSON Patch inserts array members between a common prefix and suffix" {
  let before : Json = [1, 4]
  let after : Json = [1, 2, 3, 4]
  let patches = @json_repair.diff_json_patches(before, after)
  assert_eq(patches.map(patch => (patch.op, patch.path)), [
    ("add", "/1"),
    ("add", "/2"),
  ])
  assert_eq(@json_repair.apply_json_patches(before, patches[:]).unwrap(), after)
}

///|
test "JSON Patch removes array members in descending index order" {
  let before : Json = [1, 2, 3, 4]
  let after : Json = [1, 4]
  let patches = @json_repair.diff_json_patches(before, after)
  assert_eq(patches.map(patch => (patch.op, patch.path)), [
    ("remove", "/2"),
    ("remove", "/1"),
  ])
  assert_eq(@json_repair.apply_json_patches(before, patches[:]).unwrap(), after)
}

///|
test "JSON Patch aligns shifted short array runs with two localized edits" {
  let before : Json = [1, 2, 3]
  let after : Json = [0, 1, 2]
  let patches = @json_repair.diff_json_patches(before, after)
  assert_eq(patches.map(patch => (patch.op, patch.path)), [
    ("add", "/0"),
    ("remove", "/3"),
  ])
  assert_eq(@json_repair.apply_json_patches(before, patches[:]).unwrap(), after)
}

///|
test "JSON Patch preserves a matching interior array element during substitutions" {
  let before : Json = [0, 1, 2]
  let after : Json = [9, 1, 8]
  let patches = @json_repair.diff_json_patches(before, after)
  assert_eq(patches.map(patch => (patch.op, patch.path)), [
    ("replace", "/0"),
    ("replace", "/2"),
  ])
  assert_eq(@json_repair.apply_json_patches(before, patches[:]).unwrap(), after)
}

///|
test "direct JSON Patch APIs bound recursion on manually constructed deep values" {
  let mut before = Json::number(1)
  let mut after = Json::number(2)
  for _ in 0..<258 {
    before = Json::array([before])
    after = Json::array([after])
  }
  let patches = @json_repair.diff_json_patches(before, after)
  assert_eq(patches.map(patch => patch.path), ["/0".repeat(257)])
  let patched = @json_repair.apply_json_patches(before, patches[:]).unwrap()
  assert_eq(patched.stringify(), after.stringify())
  let excessive : @json_repair.JsonPatch = {
    op: "replace",
    path: "/0".repeat(258),
    value: Some(after),
  }
  assert_true(@json_repair.apply_json_patches(before, [excessive][:]) is Err(_))
}

///|
test "JSON Patch preserves unchanged object branches and ignores member ordering" {
  let before : Json = {
    "first": [true, false, Json::null()],
    "second": { "same": "" },
  }
  let after : Json = {
    "second": { "same": "" },
    "first": [true, false, Json::null()],
  }
  assert_true(@json_repair.diff_json_patches(before, after).is_empty())
}

///|
test "JSON Patch applies RFC array append and root add" {
  let baseline : Json = [1]
  let patches : Array[@json_repair.JsonPatch] = [
    { op: "add", path: "", value: Some(baseline), },
    { op: "add", path: "/-", value: Some(Json::null()), },
  ]
  assert_eq(
    @json_repair.apply_json_patches(Json::null(), patches[:])
    .unwrap()
    .stringify(),
    "[1,null]",
  )
}

///|
test "JSON Patch rejects malformed paths, array indices, payloads, and verbs" {
  let baseline : Json = { "items": [1] }
  let errors : Array[@json_repair.JsonPatch] = [
    { op: "replace", path: "items", value: Some(Json::null()), },
    { op: "replace", path: "/items/~", value: Some(Json::null()), },
    { op: "add", path: "/items/~2", value: Some(Json::null()), },
    { op: "add", path: "/items/01", value: Some(Json::null()), },
    { op: "replace", path: "/items/-", value: Some(Json::null()), },
    { op: "replace", path: "/items/2", value: Some(Json::null()), },
    { op: "replace", path: "/items/-1", value: Some(Json::null()), },
    {
      op: "replace",
      path: "/items/99999999999999999",
      value: Some(Json::null()),
    },
    { op: "replace", path: "/items/0/x", value: Some(Json::null()), },
    { op: "add", path: "/items/", value: Some(Json::null()), },
    { op: "remove", path: "/missing", value: None, },
    { op: "remove", path: "", value: None, },
    { op: "replace", path: "", value: None, },
    { op: "move", path: "", value: None, },
  ]
  for patch in errors {
    assert_true(@json_repair.apply_json_patches(baseline, [patch][:]) is Err(_))
  }
}

///|
test "a failed JSON Patch list does not mutate the caller's baseline" {
  let baseline : Json = { "items": [1] }
  let patches : Array[@json_repair.JsonPatch] = [
    { op: "add", path: "/items/-", value: Some(Json::null()), },
    { op: "remove", path: "/items/3", value: None, },
  ]
  assert_true(@json_repair.apply_json_patches(baseline, patches[:]) is Err(_))
  assert_eq(baseline.stringify(), "{\"items\":[1]}")
}

///|
test "stream patches escape nested keys and seal physical string boundaries" {
  let stream = @json_repair.RepairStream::new()
  stream.push("{\"args\":{\"a/b~\":\"hel").unwrap()
  let first = stream.next_patches().unwrap()
  expect_seal(first, "/args/a~1b~0", false)
  expect_seal(first, "/args", false)
  expect_seal(first, "", false)
  stream.push("lo\"").unwrap()
  let second = stream.next_patches().unwrap()
  assert_eq(second.patches.map(patch => patch.path), ["/args/a~1b~0"])
  expect_seal(second, "/args/a~1b~0", true)
  expect_seal(second, "/args", false)
  let patched = @json_repair.apply_json_patches(
    first.report.value,
    second.patches[:],
  ).unwrap()
  assert_eq(patched.stringify(), second.report.json)
  stream.push("}}").unwrap()
  let last = stream.next_patches().unwrap()
  assert_true(last.patches.is_empty())
  expect_seal(last, "/args", true)
  expect_seal(last, "", true)
}

///|
test "stream sealing uses physical scalar and container delimiters" {
  let stream = @json_repair.RepairStream::new()
  stream.push("{\"args\":[1, {\"x\":true}, 42").unwrap()
  let first = stream.next_patches().unwrap()
  expect_seal(first, "/args/0", true)
  expect_seal(first, "/args/1/x", true)
  expect_seal(first, "/args/1", true)
  expect_seal(first, "/args/2", false)
  expect_seal(first, "/args", false)
  stream.push(" ,null]}").unwrap()
  let second = stream.next_patches().unwrap()
  assert_eq(second.patches.map(patch => (patch.op, patch.path)), [
    ("add", "/args/3"),
  ])
  expect_seal(second, "/args/2", true)
  expect_seal(second, "/args/3", true)
  expect_seal(second, "/args", true)
}

///|
test "stream patch error preserves the last delivered baseline" {
  let stream = @json_repair.RepairStream::new()
  stream.push("{\"x\":1").unwrap()
  let first = stream.next_patches().unwrap()
  stream.push("e").unwrap()
  assert_true(stream.next_patches() is Err(_))
  stream.push("3}").unwrap()
  let second = stream.next_patches().unwrap()
  assert_eq(second.patches.map(patch => patch.path), ["/x"])
  let patched = @json_repair.apply_json_patches(
    first.report.value,
    second.patches[:],
  ).unwrap()
  assert_eq(patched.stringify(), second.report.json)
  expect_seal(second, "/x", true)
}

///|
test "stream patch output cannot mutate its next stored baseline" {
  let stream = @json_repair.RepairStream::new()
  stream.push("{\"x\":1").unwrap()
  let frame = stream.next_patches().unwrap()
  guard frame.report.value is Object(fields) else { fail("expected an object") }
  fields["x"] = Json::null()
  stream.push("}").unwrap()
  assert_true(stream.next_patches().unwrap().patches.is_empty())
}

///|
test "stream patch reset returns to null baseline" {
  let stream = @json_repair.RepairStream::new()
  stream.push("[]").unwrap()
  assert_eq(stream.scanned_units(), 2)
  assert_eq(stream.next_patches().unwrap().patches.length(), 1)
  stream.reset()
  assert_eq(stream.scanned_units(), 0)
  stream.push("[]").unwrap()
  assert_eq(stream.next_patches().unwrap().patches.length(), 1)
}

///|
test "thought policy excludes draft values from patches and field seals" {
  let policy = @json_repair.RepairOptions::default().with_ignore_think_blocks(
    true,
  )
  let stream = @json_repair.RepairStream::with_policy(policy)
  stream
  .push("<think>{\"ignored\":\"guess\"}</think>{\"ok\":{\"v\":\"x")
  .unwrap()
  let frame = stream.next_patches().unwrap()
  assert_false(frame.report.json.contains("ignored"))
  assert_true(frame.fields.all(field => !field.pointer.contains("ignored")))
  expect_seal(frame, "/ok/v", false)
  stream.push("\" }}").unwrap()
  let resolved = stream.next_patches().unwrap()
  expect_seal(resolved, "/ok/v", true)
  assert_eq(resolved.report, stream.finalize().unwrap())
}

///|
test "synthetic delimiters remain unsealed after transport finalization" {
  let stream = @json_repair.RepairStream::new()
  stream.push("{\"name\":\"unfinished").unwrap()
  ignore(stream.finalize().unwrap())
  let frame = stream.next_patches().unwrap()
  expect_seal(frame, "", false)
  expect_seal(frame, "/name", false)
}
