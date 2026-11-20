///|
fn scaling_payload(bytes : Int32) -> String {
  let row =
    #|{"tool":"quote","args":{"id":9007199254740993,"limit":42,"enabled":True}},
  let tail =
    #|{"text":"
  let capacity = bytes - 1 - tail.length()
  let rows = capacity / row.length()
  "[" + row.repeat(rows) + tail + "x".repeat(capacity % row.length())
}

///|
test "repair scaling across four malformed ASCII tool-call payloads" (
  bench : @bench.T,
) {
  for size in [200, 2_000, 20_000, 100_000] {
    let payload = scaling_payload(size)
    guard payload.length() == size &&
      @json_repair.repair(payload) is Ok({ edits, .. }) &&
      edits.length() > 0 else {
      abort("malformed benchmark payload must be repairable")
    }
    bench.bench(name="scale-\{size}", () => {
      bench.keep(@json_repair.repair(payload))
    })
  }
}

///|
fn run_preview_path(
  chunks : Array[String],
  each_chunk : Bool,
) -> @json_repair.RepairReport {
  let stream = @json_repair.RepairStream::new()
  for chunk in chunks {
    stream.push(chunk).unwrap()
    if each_chunk {
      ignore(stream.preview())
    }
  }
  stream.finalize().unwrap()
}

///|
test "stream preview per chunk and one final parse" (bench : @bench.T) {
  let payload = scaling_payload(1024)
  let expected = @json_repair.repair(payload).unwrap()
  for width in [16, 64, 256] {
    let chunks = []
    let mut at = 0
    while at < payload.length() {
      let end = if at + width < payload.length() {
        at + width
      } else {
        payload.length()
      }
      chunks.push(payload[at:end].to_owned())
      at = end
    }
    for each_chunk in [true, false] {
      let report = run_preview_path(chunks, each_chunk)
      guard report.json == expected.json && report.edits == expected.edits else {
        abort("stream paths must preserve the exact JSON and audit log")
      }
      let mode = if each_chunk { "preview" } else { "final" }
      bench.bench(name="stream-\{mode}-\{width}", () => {
        bench.keep(run_preview_path(chunks, each_chunk))
      })
    }
  }
}
