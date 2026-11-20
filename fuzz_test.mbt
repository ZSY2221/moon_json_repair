///|
priv struct FuzzPrng {
  mut state : UInt32
}

///|
fn FuzzPrng::pick(self : FuzzPrng, bound : Int32) -> Int32 {
  let mut n = self.state
  n = n ^ (n << 13)
  n = n ^ (n >> 17)
  n = n ^ (n << 5)
  self.state = n
  (n % bound.reinterpret_as_uint()).reinterpret_as_int()
}

///|
priv enum FuzzFamily {
  RandomUtf8
  TruncatedUtf16
  CodeUnitPrefix
  JsonMutation
  EscapeStorm
  DeepStack
}

///|
let fuzz_documents : Array[String] = [
  (
    #|{"tool":"quote","args":{"id":9007199254740993,"word":"繁🌙","tags":[true,null]}}
  ),
  (
    #|[{"a":-1.2200e+8,"long":"\uD83D\uDE00 \b\f\r\t\n\\\""},false,{"\u0041":42}]
  ),
  (
    #|{"text":"𐐷 é 👩‍🚀","nested":[[[0,[["key"]]]]],"unicode":"\u00e9"}
  ),
  (
    #|[[],{"keywords":["\"{}[]\"","*/ //","é&"]},1.25,42]
  ),
]

///|
let fuzz_fragments : Array[String] = [
  "{", "]", "}", "[", ":", ",", "'", "\"", "\\", "\\u", "\\uDA7e", "\\uXXac", "\\uD83D\\uDE",
  "😀", "\r\n", "\u{0000}", "\t", "/*", "*/", "//", " \r", "x", "1e+", "9999",
  "0xFF", "True", "None", "undefined", "fé", "[-.5", "+10", "\uFEFF", "é",
]

///|
fn sample_fuzz_input(rng : FuzzPrng, family : FuzzFamily) -> String {
  let body = fuzz_documents[rng.pick(fuzz_documents.length())]
  match family {
    RandomUtf8 => {
      let bytes = Bytes::makei(rng.pick(80) + 1, _ => rng.pick(256).to_byte())
      let text = @utf8.decode_lossy(bytes[:])
      match rng.pick(3) {
        0 => text
        1 => "{\"text\":\"" + text
        _ => "[" + text + ",0]"
      }
    }
    TruncatedUtf16 => {
      let bytes = @utf16.encode(body[:], endianness=Little)
      let end = rng.pick(bytes.length() + 1)
      @utf16.decode_lossy(bytes[:end], endianness=Little)
    }
    // All bounds are checked by construction. A cut can separate a surrogate pair.
    CodeUnitPrefix =>
      body.unsafe_substring(start=0, end=rng.pick(body.length() + 1))
    JsonMutation => {
      let out = StringBuilder()
      let mut at = 0
      for _ in 0..<(rng.pick(5) + 1) {
        let edge = at + rng.pick(body.length() - at + 1)
        out.write_string(body.unsafe_substring(start=at, end=edge))
        out.write_string(fuzz_fragments[rng.pick(fuzz_fragments.length())])
        at = edge + rng.pick(body.length() - edge + 1)
      }
      out.write_string(body.unsafe_substring(start=at, end=body.length()))
      out.to_string()
    }
    EscapeStorm => {
      let out = StringBuilder()
      out.write_string(if rng.pick(2) == 0 { "[\"" } else { "['" })
      for _ in 0..<(rng.pick(90) + 1) {
        out.write_string(fuzz_fragments[rng.pick(fuzz_fragments.length())])
      }
      out.to_string()
    }
    DeepStack => {
      let depth = rng.pick(244)
      let closed = rng.pick(depth + 1)
      "[".repeat(depth) + body + "]".repeat(closed)
    }
  }
}

///|
fn verify_fuzz_invariants(input : String) -> Unit raise {
  verify_fuzz_result(input, @json_repair.repair(input))
}

///|
fn verify_fuzz_result(
  input : String,
  result : Result[@json_repair.RepairReport, @json_repair.RepairError],
) -> Unit raise {
  match result {
    Ok(report) => {
      let strict = @json.parse(
        report.json[:],
        max_nesting_depth=257,
        preserve_number_repr=true,
        reject_duplicate_keys=true,
      )
      assert_eq(strict.stringify(), report.value.stringify())
      let second = @json_repair.repair(report.json).unwrap()
      assert_eq(second.json, report.json)
      assert_eq(second.edits.length(), 0)
      for edit in report.edits {
        assert_true(edit.position.offset >= 0)
        assert_true(edit.end_offset >= edit.position.offset)
        assert_true(edit.end_offset <= input.length())
      }
    }
    Err(error) => {
      assert_true(error.position.offset >= 0)
      assert_true(error.position.offset <= input.length())
      assert_true(error.position.line >= 1)
      assert_true(error.position.column >= 1)
    }
  }
}

///|
fn verify_fuzz_extended(input : String) -> Unit raise {
  let options : @json_repair.RepairOptions = {
    ..@json_repair.RepairOptions::default(),
    json5: true,
  }
  verify_fuzz_result(input, @json_repair.repair_with_options(input, options))
  match @json_repair.extract_all(input, options) {
    Err(error) =>
      assert_true(
        error.position.offset >= 0 && error.position.offset <= input.length(),
      )
    Ok(blocks) => {
      let mut end = 0
      for block in blocks {
        assert_true(block.start.offset >= end)
        assert_true(block.end.offset > block.start.offset)
        assert_true(block.end.offset <= input.length())
        assert_true(block.confidence >= 0 && block.confidence <= 100)
        verify_fuzz_result(input, Ok(block.report))
        for edit in block.report.edits {
          assert_true(
            edit.position.offset >= block.start.offset &&
            edit.end_offset <= block.end.offset,
          )
        }
        end = block.end.offset
      }
    }
  }
}

///|
fn run_fuzz_batch(family : FuzzFamily, seed : UInt32) -> Unit raise {
  let rng = { state: seed, }
  for index in 0..<100 {
    let sample = sample_fuzz_input(rng, family)
    try {
      verify_fuzz_invariants(sample)
      verify_fuzz_extended(sample)
    } catch {
      error => fail("seed \{seed}, sample \{index}: \{error.to_string()}")
    }
  }
}

///|
test "fuzz arbitrary byte transport seed 2654435769" {
  run_fuzz_batch(RandomUtf8, 2654435769U)
}

///|
test "fuzz arbitrary byte transport seed 2655511694" {
  run_fuzz_batch(RandomUtf8, 2655511694U)
}

///|
test "fuzz arbitrary byte transport seed 2656587619" {
  run_fuzz_batch(RandomUtf8, 2656587619U)
}

///|
test "fuzz arbitrary byte transport seed 2657663544" {
  run_fuzz_batch(RandomUtf8, 2657663544U)
}

///|
test "fuzz UTF-16 byte cut seed 2658739469" {
  run_fuzz_batch(TruncatedUtf16, 2658739469U)
}

///|
test "fuzz UTF-16 byte cut seed 2659815394" {
  run_fuzz_batch(TruncatedUtf16, 2659815394U)
}

///|
test "fuzz UTF-16 byte cut seed 2660891319" {
  run_fuzz_batch(TruncatedUtf16, 2660891319U)
}

///|
test "fuzz UTF-16 byte cut seed 2661967244" {
  run_fuzz_batch(TruncatedUtf16, 2661967244U)
}

///|
test "fuzz raw UTF-16 prefix seed 2663043169" {
  run_fuzz_batch(CodeUnitPrefix, 2663043169U)
}

///|
test "fuzz raw UTF-16 prefix seed 2664119094" {
  run_fuzz_batch(CodeUnitPrefix, 2664119094U)
}

///|
test "fuzz raw UTF-16 prefix seed 2665195019" {
  run_fuzz_batch(CodeUnitPrefix, 2665195019U)
}

///|
test "fuzz raw UTF-16 prefix seed 2666270944" {
  run_fuzz_batch(CodeUnitPrefix, 2666270944U)
}

///|
test "fuzz valid JSON mutation seed 2667346869" {
  run_fuzz_batch(JsonMutation, 2667346869U)
}

///|
test "fuzz valid JSON mutation seed 2668422794" {
  run_fuzz_batch(JsonMutation, 2668422794U)
}

///|
test "fuzz valid JSON mutation seed 2669498719" {
  run_fuzz_batch(JsonMutation, 2669498719U)
}

///|
test "fuzz valid JSON mutation seed 2670574644" {
  run_fuzz_batch(JsonMutation, 2670574644U)
}

///|
test "fuzz escape storm seed 2671650569" {
  run_fuzz_batch(EscapeStorm, 2671650569U)
}

///|
test "fuzz escape storm seed 2672726494" {
  run_fuzz_batch(EscapeStorm, 2672726494U)
}

///|
test "fuzz escape storm seed 2673802419" {
  run_fuzz_batch(EscapeStorm, 2673802419U)
}

///|
test "fuzz escape storm seed 2674878344" {
  run_fuzz_batch(EscapeStorm, 2674878344U)
}

///|
test "fuzz container and depth seed 2675954269" {
  run_fuzz_batch(DeepStack, 2675954269U)
}

///|
test "fuzz container and depth seed 2677030194" {
  run_fuzz_batch(DeepStack, 2677030194U)
}

///|
test "fuzz container and depth seed 2678106119" {
  run_fuzz_batch(DeepStack, 2678106119U)
}

///|
test "fuzz container and depth seed 2679182044" {
  run_fuzz_batch(DeepStack, 2679182044U)
}

///|
test "a 220-level truncated stack repairs under explicit depth limit" {
  let source = "[".repeat(220) + "0"
  let requested : @json_repair.RepairLimits = {
    ..@json_repair.RepairLimits::default(),
    max_depth: 224,
  }
  let result = @json_repair.repair(source, limits=requested).unwrap()
  assert_eq(result.json, source + "]".repeat(220))
  let parsed = @json.parse(result.json[:], max_nesting_depth=225)
  assert_true(parsed is Array(_))
  assert_eq(
    @json_repair.repair(result.json, limits=requested).unwrap().json,
    result.json,
  )
}

///|
test "a 257-level truncated stack is rejected before recursion exceeds the clamp" {
  let source = "[".repeat(257)
  let requested : @json_repair.RepairLimits = {
    ..@json_repair.RepairLimits::default(),
    max_depth: 800,
  }
  guard @json_repair.repair(source, limits=requested) is Err(err) else {
    fail("depth clamp did not fire")
  }
  assert_eq(err.kind.code(), "depth_limit")
  assert_eq(err.position.offset, 256)
}

///|
test "long escape storm is completed with bounded edits" {
  let source = "{\"x\":\"" + "\\uD83D\\uDE03".repeat(9000)
  let result = @json_repair.repair(source).unwrap()
  assert_eq(result.json, source + "\"}")
  assert_eq(result.edits.length(), 2)
  verify_fuzz_invariants(source)
}

///|
test "unescaped quote storm rejects without a runaway scan" {
  let source = "{\"x\":\"" + "\"".repeat(105_000)
  guard @json_repair.repair(source) is Err(err) else {
    fail("quote storm should reject")
  }
  assert_eq(err.kind.code(), "unexpected_token")
}

///|
test "a 100 KB cut string retains its entire body and remains idempotent" {
  let source = "{\"x\":\"" + "x".repeat(99_994)
  assert_eq(source.length(), 100_000)
  let result = @json_repair.repair(source).unwrap()
  assert_eq(result.json.length(), 100_002)
  verify_fuzz_invariants(source)
}

///|
test "long exact numeric representation survives the JSON AST" {
  let digits = "9876543210".repeat(6000)
  let result = @json_repair.repair("[" + digits).unwrap()
  assert_eq(result.json, "[" + digits + "]")
  assert_eq(result.value.stringify(), result.json)
  verify_fuzz_invariants("[" + digits)
}

///|
test "native string and UTF-8 decoding agree on a well-formed emoji" {
  let utf8 = @utf8.encode("👩‍🚀")
  assert_eq(@utf8.decode(utf8[:]), "👩‍🚀")
  let utf16 = @utf16.encode("👩‍🚀", endianness=Big)
  assert_eq(@utf16.decode(utf16[:], endianness=Big), "👩‍🚀")
  verify_fuzz_invariants("{\"astronaut\":\"👩‍🚀")
}

///|
test "streaming all raw UTF-16 boundaries reconstructs an exact report" {
  let source = "{\"emoji\":\"🌙👩‍🚀\",\"id\":9007199254740993"
  let stream = @json_repair.RepairStream::new()
  for index in 0..<source.length() {
    let chunk = source.unsafe_substring(start=index, end=index + 1)
    stream.push(chunk).unwrap()
    assert_eq(stream.status().position.offset, index + 1)
  }
  let expected = @json_repair.repair(source).unwrap()
  let finalized = stream.finalize().unwrap()
  assert_eq(finalized.json, expected.json)
  assert_eq(finalized.edits, expected.edits)
}
