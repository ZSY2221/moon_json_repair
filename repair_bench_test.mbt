///|
test "repair strict array of 100 tool calls" (bench : @bench.T) {
  let row =
    #|{"tool":"quote","args":{"amount":125.50,"currency":"SGD","tags":["llm","moonbit"]}}
  let payload = "[" + Array::make(100, row).join(",") + "]"
  guard @json_repair.repair(payload) is Ok({ edits: [], .. }) else {
    abort("invalid strict benchmark fixture")
  }
  bench.bench(name="strict \{payload.length()} UTF-16 units", () => {
    bench.keep(@json_repair.repair(payload))
  })
}

///|
test "repair 100 LLM tool calls with mixed damage and truncated last array" (
  bench : @bench.T,
) {
  let row =
    #|{tool:'quote',args:{amount:125.50,currency:'SGD',ready:True,tags:['llm' 'moonbit'],},}
  let payload = "Tool calls:\n[" + Array::make(100, row).join(",\n")
  guard @json_repair.repair(payload) is Ok({ value: Array(calls), edits, .. }) &&
    calls.length() == 100 &&
    edits.length() > 100 else {
    abort("invalid damaged benchmark fixture")
  }
  bench.bench(name="damaged \{payload.length()} UTF-16 units", () => {
    bench.keep(@json_repair.repair(payload))
  })
}

///|
test "repair and validate a truncated payment tool call" (bench : @bench.T) {
  let payload =
    #|{tool:'quote',args:{amount:125.50,currency:'SGD',tags:['llm'
  let schema : Json = {
    "type": "object",
    "required": ["tool", "args"],
    "properties": {
      "tool": { "enum": ["quote"] },
      "args": {
        "type": "object",
        "required": ["amount", "currency", "tags"],
        "properties": {
          "amount": { "type": "number", "minimum": 0 },
          "currency": { "enum": ["SGD", "USD"] },
          "tags": {
            "type": "array",
            "items": { "type": "string", "minLength": 1 },
          },
        },
      },
    },
  }
  guard @json_repair.repair(payload) is Ok(report) &&
    @json_repair.validate(report.value, schema).is_empty() else {
    abort("invalid end-to-end benchmark fixture")
  }
  bench.bench(name="repair + schema \{payload.length()} UTF-16 units", () => {
    if @json_repair.repair(payload) is Ok(report) {
      bench.keep(@json_repair.validate(report.value, schema))
    }
  })
}

///|
test "hot text payload benchmarks" (bench : @bench.T) {
  let ascii = "{\"message\":\"" + "text".repeat(25_000)
  let rows = "MoonBit \u{1F319} agent output\\n".repeat(4_100)
  let escaped = "{\"message\":\"" + rows
  for (name, input) in [("text-ascii", ascii), ("text-escaped", escaped)] {
    let expected = @json_repair.repair(input).unwrap()
    guard expected.edits.length() == 2 else {
      abort("fixture must require two closing edits")
    }
    bench.bench(name~, () => bench.keep(@json_repair.repair(input)))
  }
}

///|
test "incremental checkpoint benchmarks" (bench : @bench.T) {
  let shard = "MoonBit tool output \u{1F319}: 9007199254740993"
  bench.bench(name="push-only-2000", () => {
    let stream = @json_repair.RepairStream::new()
    stream.push("{\"message\":\"").unwrap()
    for _ in 0..<2000 {
      stream.push(shard).unwrap()
    }
    bench.keep(stream.status())
  })
}
