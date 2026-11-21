///|
fn write_file_benchmark_payload(bytes : Int32) -> String {
  let head =
    #|{"tool":"write_file","args":{"path":"main.mbt","content":"
  let line =
    #|fn greet(name : String) -> Unit {\n  println(\"hello \" + name)\n}\n
  let tail =
    #|","id":9007199254740993}}
  let content_bytes = bytes - head.length() - tail.length()
  head +
  line.repeat(content_bytes / line.length()) +
  " ".repeat(content_bytes % line.length()) +
  tail
}

///|
fn write_file_benchmark_chunks(
  payload : String,
  width : Int32,
) -> Array[String] {
  let chunks = []
  let view = payload[:]
  for at = 0; at < view.length(); at = at + width {
    let end = (at + width).min(view.length())
    chunks.push(view.exact_view(start=at, end~).to_owned())
  }
  chunks
}

///|
fn write_file_benchmark_oracle(chunks : Array[String]) -> Unit raise {
  let policy = @json_repair.RepairPolicy::default()
  let live = @json_repair.RepairStream::with_policy(policy)
  let reference = @json_repair.RepairStream::with_uncached_policy(policy)
  for chunk in chunks {
    live.push(chunk).unwrap()
    reference.push(chunk).unwrap()
    assert_eq(live.preview(), reference.preview())
    let frame = live.next_patches().unwrap()
    let expected = reference.next_patches().unwrap()
    assert_eq(frame.report, expected.report)
    assert_eq(frame.fields, expected.fields)
    assert_eq(frame.patches.length(), expected.patches.length())
    for index in 0..<frame.patches.length() {
      assert_eq(
        @json.to_json(frame.patches[index]).stringify(),
        @json.to_json(expected.patches[index]).stringify(),
      )
    }
  }
  assert_eq(live.finalize(), reference.finalize())
}

///|
fn time_write_file_benchmark(
  chunks : Array[String],
  cached : Bool,
  patches : Bool,
) -> Int32 {
  let policy = @json_repair.RepairPolicy::default()
  let stream = if cached {
    @json_repair.RepairStream::with_policy(policy)
  } else {
    @json_repair.RepairStream::with_uncached_policy(policy)
  }
  let mut bytes = 0
  for chunk in chunks {
    stream.push(chunk).unwrap()
    if patches {
      let frame = stream.next_patches().unwrap()
      bytes += frame.report.json.length() +
        frame.fields.length() +
        frame.patches.length()
    } else {
      bytes += stream.preview().unwrap().json.length()
    }
  }
  bytes
}

///|
test "write_file streaming sessions over complete 10 and 50 KB JSON inputs" (
  bench : @bench.T,
) {
  for bytes in [10_000, 50_000] {
    let payload = write_file_benchmark_payload(bytes)
    assert_eq(payload.length(), bytes)
    for width in [64, 256] {
      let chunks = write_file_benchmark_chunks(payload, width)
      write_file_benchmark_oracle(chunks)
      for patches in [false, true] {
        let operation = if patches { "patch" } else { "preview" }
        for cached in [false, true] {
          let path = if cached { "cached" } else { "reference" }
          bench.bench(
            name="write-file-\{operation}-\{path}-\{bytes}-\{width}",
            () => bench.keep(time_write_file_benchmark(chunks, cached, patches)),
          )
        }
      }
    }
  }
}
