///|
// Recreate the v0.2.0 checkpoint query: each poll copied the accumulator,
// located every thought block, materialized the mask and framed it from zero.
fn reference_think_status(
  input : String,
  options : RepairOptions,
) -> StreamStatus {
  let cursor = Cursor::new(input[:], options.limits, json5=options.json5)
  let masked = mask_think_ranges(input, cursor.think_ranges())
  let scanner = RepairStream::with_options(options)
  scanner.observe_chunk(masked[:])
  scanner.status()
}

///|
fn checkpoint_policy() -> RepairPolicy {
  RepairOptions::default().with_ignore_think_blocks(true)
}

///|
fn checkpoint_chunks(source : String, width : Int32) -> Array[String] {
  let parts = []
  for at = 0; at < source.length(); at = at + width {
    let end = (at + width).min(source.length())
    parts.push(source[:].exact_view(start=at, end~).to_owned())
  }
  parts
}

///|
fn poll_think_incremental(
  parts : Array[String],
  policy : RepairPolicy,
) -> Int32 {
  let stream = RepairStream::with_policy(policy)
  let mut checksum = 0
  for part in parts {
    stream.push(part).unwrap()
    let status = stream.status()
    checksum += status.depth + status.stable_offset
  }
  checksum
}

///|
fn poll_think_reference(parts : Array[String], policy : RepairPolicy) -> Int32 {
  let stream = RepairStream::with_options(policy.options)
  let mut checksum = 0
  for part in parts {
    // v0.2 recorded only positions while appending filtered stream input.
    stream.buffer.write_string(part)
    let units = part[:]
    for i in 0..<units.length() {
      stream.advance_position(char_at(units, i))
    }
    let status = reference_think_status(
      stream.buffer.to_string(),
      policy.options,
    )
    checksum += status.depth + status.stable_offset
  }
  checksum
}

///|
fn assert_think_final(
  input : String,
  chunks : Array[String],
  policy : RepairPolicy,
) -> Unit {
  let stream = RepairStream::with_policy(policy)
  for chunk in chunks {
    stream.push(chunk).unwrap()
  }
  guard stream.finalize() is Ok(streamed) &&
    repair_with_policy(input, policy) is Ok(batch) &&
    streamed.json == batch.json &&
    streamed.edits == batch.edits &&
    stream.scanned_units() == input.length() else {
    abort("incremental and one-shot thought reports must be identical")
  }
}

///|
fn unclosed_thought_bytes(bytes : Int32) -> String {
  let start = "{\"tool\":\"balance\",\"args\":{\"id\":9007199254740993}}<think>\r\n"
  start + "x".repeat(bytes - start.length())
}

///|
test "filtered stream polls at three chunk widths and under unclosed draft load" (
  bench : @bench.T,
) {
  let policy = checkpoint_policy()
  let opening = "<ThInK>{\"draft\": \"reason "
  let ending = "\"}</ThInK>\r\n{\"tool\":\"balance\",\"args\":{\"id\":9007199254740993"
  let sample = opening +
    "x".repeat(1024 - opening.length() - ending.length()) +
    ending
  for width in [16, 64, 256] {
    let chunks = checkpoint_chunks(sample, width)
    assert_think_final(sample, chunks, policy)
    guard poll_think_incremental(chunks, policy) ==
      poll_think_reference(chunks, policy) else {
      abort(
        "incremental and v0.2 checkpoints must agree on the benchmark sample",
      )
    }
    bench.bench(name="think-checkpoint-\{width}", () => {
      bench.keep(poll_think_incremental(chunks, policy))
    })
    bench.bench(name="think-reference-\{width}", () => {
      bench.keep(poll_think_reference(chunks, policy))
    })
    let short = unclosed_thought_bytes(5_000)
    let small_chunks = checkpoint_chunks(short, width)
    assert_think_final(short, small_chunks, policy)
    bench.bench(name="think-unclosed-small-\{width}", () => {
      bench.keep(poll_think_incremental(small_chunks, policy))
    })
    let long = unclosed_thought_bytes(50_000)
    let long_chunks = checkpoint_chunks(long, width)
    assert_think_final(long, long_chunks, policy)
    bench.bench(name="think-unclosed-\{width}", () => {
      bench.keep(poll_think_incremental(long_chunks, policy))
    })
    if width == 256 {
      bench.bench(name="think-unclosed-reference-256", () => {
        bench.keep(poll_think_reference(long_chunks, policy))
      })
    }
  }
}

///|
test "incremental status matches masked reference across every code-unit cut" {
  let sources = [
    "<ThInK>\r\n{\"draft\":\"incomplete\r\n</tHiNk>\r\n{\"answer\":9007199254740993}",
    "<think>{\"draft\":\"\n</think>\ntext\"}\n{\"also_draft\":1}\n</think>\n{\"body\":2}",
    "A note [this isn't JSON\n<think>{\"draft\":1}</think>{\"body\":2}", "<think>before<THINK>[1,2]</think>after</THINK>{\"ok\":true}",
    "{\"arg\":\"<think>literal</think>\",\"count\":3}<think>{\"ignored\":1}", "prefix {key : '<think>literal</think>'} // suffix",
    "[]</not_a_tag><ThINx>", "{\"arg\":\"</think>\"} <ThInK><tag>draft", "{\"a\":42}<think>draft</think>\r\n",
    "prefix [True,False,null,None] and <think>[undefined,false]</think>[12]", "prefix [falsehood here isn't an array]<think>[]</think>{\"a\":1}",
    "prefix { not a : formal key with no comma <think>[]</think>{\"a\":1}", "prefix {exact:/\\* accidental}<think>{\"a\":\"text\"}</think>[0]",
    "prefix {bad key} <think>{\"a\":false}</think> {\"b\":3}", "prefix {x9\r\n:<think>{plain:0}</think>'<think>literal</think>'}",
    "prefix {x/ * not a comment quote '<think>literal</think>'}", "<THINK>{\"tag\":\"\n<?xml\n</think> more\nstill\\\\\"} \n</think> {}",
    "<think>{'tag':'\n</think>\n; no quote yet \\' then an apostrophe'}\n</think> {}",
    "<think>{\"tag\":\"\n</think>\n{\"outer\":\"ok\"}", "<think>draft </x/><THINK>nested</think></think>{\"b\":2}",
    "<think>draft </**/></think>{\"b\":3}", "prefix [<think>draft</think> {\"tag\":\"<think>during payload</think>\"}]",
    "prefix {punct!uation <think>draft</think> {\"answer\":0}", "<think><think>{\"draft\":\"unfinished\n</think>\n{\"stillDraft\":2}\n</think>\n{\"answer\":3}",
    "<think>{\"draft\":\"unfinished\n</think>\nquote\" \t }\n</think>{\"answer\":3}",
    "<think>[/* literal </think> */ 1]</think>{\"answer\":3}", "<think>{] mismatched draft</think>{\"answer\":3}",
  ]
  let policy = checkpoint_policy()
  for token in ["true", "false", "null", "True", "False", "None", "undefined"] {
    let raw = "prefix [" +
      token +
      ",\"<think>literal</think>\"] <think>draft</think>"
    let stream = RepairStream::with_policy(policy)
    for part in checkpoint_chunks(raw, 2) {
      stream.push(part).unwrap()
    }
    assert_eq(stream.status(), reference_think_status(raw, policy.options))
    assert_eq(stream.finalize(), repair_with_policy(raw, policy))
  }
  for raw in sources {
    let stream = RepairStream::with_policy(policy)
    for at in 0..<raw.length() {
      let next = raw[:].exact_view(start=at, end=at + 1)
      stream.push(next.to_owned()).unwrap()
      assert_eq(stream.scanned_units(), at + 1)
      assert_eq(
        stream.status(),
        reference_think_status(
          raw[:].exact_view(end=at + 1).to_owned(),
          policy.options,
        ),
        msg=raw[:].exact_view(end=at + 1).to_owned(),
      )
      assert_eq(stream.scanned_units(), at + 1)
    }
    assert_eq(stream.finalize(), repair_with_policy(raw, policy))
  }
}

///|
fn verify_overlapping_think_recovery(
  source : String,
  expected_json : String,
  max_chunk : UInt32,
  seed : UInt32,
) -> Unit raise {
  let policy = checkpoint_policy()
  let stream = RepairStream::with_policy(policy)
  let mut state = seed
  let mut start = 0
  while start < source.length() {
    state = state ^ (state << 13)
    state = state ^ (state >> 17)
    state = state ^ (state << 5)
    let width = 1 + (state % max_chunk).reinterpret_as_int()
    let end = (start + width).min(source.length())
    stream.push(source[:].exact_view(start~, end~).to_owned()).unwrap()
    let prefix = source[:].exact_view(end~).to_owned()
    let expected = reference_think_status(prefix, policy.options)
    assert_eq(stream.status(), expected, msg=prefix)
    assert_eq(stream.scanned_units(), end)
    start = end
  }
  let expected = reference_think_status(source, policy.options)
  assert_true(expected.stable, msg=source)
  let batch = repair_with_policy(source, policy).unwrap()
  assert_eq(batch.json, expected_json, msg=source)
  assert_eq(stream.finalize().unwrap(), batch)
  assert_eq(stream.status(), { ..expected, finalized: true, })
  assert_eq(stream.scanned_units(), source.length())
}

///|
test "incremental think status retains overlapping quote recovery checkpoints" {
  let cases = [
    (
      "<think><think>{\"draft\":\"unfinished\n</think>\n{'next':'\n</think>\n{\"answer\":\"'body\"}",
      "{\"answer\":\"'body\"}",
    ),
    (
      "<think><think>{'draft':'unfinished\n</think>\n{\"next\":\"\n</think>\n{\"answer\":\"'body\"}",
      "{\"answer\":\"'body\"}",
    ),
    (
      "<think><think>{\"draft\":\"unfinished\n</think>\n{next:\\\"\n</think>\n{\"answer\":\"x\"}",
      "{\"answer\":\"x\"}",
    ),
    (
      "<ThInK><think>{\"draft\":\"unfinished\r\n\t</ThInK> \t\r\n{'next':'\r\n  </think>\t\r\n{\"answer\":\"'body\"}",
      "{\"answer\":\"'body\"}",
    ),
    (
      "<think><think><think>{\"draft\":\"unfinished\n</think>\n{'next':'\n</think>\n{\"answer\":\"'body\"}\n</think>\n{\"id\":9007199254740993}",
      "{\"id\":9007199254740993}",
    ),
    (
      "<think><think>{\"draft\":\"unfinished\n</think>\n{'next':'\n</think>\nprotected' }\n</think>\n{\"answer\":7}",
      "{\"answer\":7}",
    ),
    (
      "<think><think>{\"draft\":\"unfinished\n</think>\n{'next':'\n</think> same line\nliteral' }\n</think>\n{\"answer\":8}",
      "{\"answer\":8}",
    ),
  ]
  for inputs in cases {
    let (source, expected_json) = inputs
    verify_overlapping_think_recovery(source, expected_json, 1U, 127891247U)
    for seed in [127891247U, 2654435769U, 2662295122U] {
      verify_overlapping_think_recovery(source, expected_json, 19U, seed)
    }
  }
}

///|
test "thought audit merge retains edit budgets at single and extraction boundaries" {
  let defaults = checkpoint_policy()
  let options = defaults.options
  let limits = { ..options.limits, max_edits: 1, }
  let policy = { ..defaults, options: { ..options, limits, }, }
  let input = "<think>draft</think>{plain:1}"
  let single = repair_with_policy(input, policy).unwrap_err()
  let extracted = extract_all_with_policy(input, policy).unwrap_err()
  assert_eq(single, extracted)
  assert_eq(single.kind, EditLimit)
  assert_eq(single.position.offset, "<think>draft</think>{".length())
}
