///|
fn decode_sse_for_test(
  source : Bytes,
  width : Int32,
  max_chars~ : Int32 = 1_048_576,
) -> Array[SseInput] {
  let decoder = SseDecoder::new(max_chars~)
  let decoded = []
  for start = 0; start < source.length(); {
    let end = (start + width).min(source.length())
    let bytes = source[start:end]
    for offset = 0; offset < bytes.length(); {
      let (next, record) = decoder.next(bytes, offset)
      if record is Some(record) {
        decoded.push(record)
      }
      continue next
    }
    continue end
  }
  if decoder.finish() is Some(record) {
    decoded.push(record)
  }
  decoded
}

///|
fn run_sse_for_test(
  source : String,
  switches : Array[String],
  schema? : Json,
) -> (Array[Json], Int32) raise CliFailure {
  let options = parse_args(switches[:])
  let gateway = SseGateway::new(options, schema)
  let output = []
  for input in decode_sse_for_test(@utf8.encode(source), 7) {
    for record in gateway.consume(input) {
      output.push(record)
    }
  }
  for record in gateway.finish(100L) {
    output.push(record)
  }
  (output, gateway.exit_status())
}

///|
fn sse_for_test(data : Json) -> String {
  "data: \{data.stringify()}\n\n"
}

///|
fn chat_for_test(
  arguments : String,
  message_id~ : String = "chat",
  choice~ : Int32 = 0,
  index~ : Int32 = 0,
  name~ : String = "check",
  id? : String,
) -> String {
  let call : Map[String, Json] = {
    "index": @json.to_json(index),
    "function": {
      "name": Json::string(name),
      "arguments": Json::string(arguments),
    },
  }
  if id is Some(id) {
    call["id"] = Json::string(id)
  }
  sse_for_test({
    "id": Json::string(message_id),
    "choices": [
      {
        "index": @json.to_json(choice),
        "delta": {
          "reasoning_content": "{\"do_not_emit\":true}",
          "content": "{\"discard\":true}",
          "tool_calls": [Json::object(call)],
        },
      },
    ],
  })
}

///|
fn claude_for_test(
  kind : String,
  index : Int32,
  fields : Map[String, Json],
) -> String {
  fields["type"] = Json::string(kind)
  fields["index"] = @json.to_json(index)
  "event: \{kind}\r\n" + sse_for_test(Json::object(fields))
}

///|
test "SSE options preserve defaults and their incompatible modes are rejected" {
  let defaults = parse_args([])
  assert_false(defaults.sse)
  assert_false(defaults.emit_patches)
  let options = parse_args(["--sse", "--emit-patches", "--strict-exit", "-"])
  assert_true(options.sse)
  assert_true(options.emit_patches)
  assert_true(options.strict_exit)
  assert_eq(options.input, None)
  for
    args in [
      ["--emit-patches"],
      ["--ndjson", "--sse"],
      ["--sse", "--extract-all"],
    ] {
    try parse_args(args[:]) catch {
      CliFailure(error, status) => {
        assert_true(error is { "kind": "usage", .. })
        assert_eq(status, 2)
      }
    } noraise {
      _ => fail("incompatible SSE switches accepted")
    }
  }
}

///|
test "SSE framing dispatches blank-line bounded events without EOF" {
  let decoder = SseDecoder::new(max_chars=100)
  let (size, input) = decoder.next(b"data:{}\n"[:], 0)
  assert_eq(size, 8)
  assert_true(input is None)
  let (_, input) = decoder.next(b"\n"[:], 0)
  guard input is Some({ line: 1L, frame: Ok(frame), }) else {
    fail("did not dispatch event")
  }
  assert_eq(frame.event_type, "message")
  assert_eq(frame.data, "{}")
}

///|
test "SSE framing handles CR, LF, and CRLF split across bytes" {
  let source = b"event: update\rdata: first\r\ndata: second\n\rdata: third\r\r"
  let frames = decode_sse_for_test(source, 1)
  assert_eq(frames.length(), 2)
  let first = frames[0].frame.unwrap()
  let second = frames[1].frame.unwrap()
  assert_eq(first.event_type, "update")
  assert_eq(first.data, "first\nsecond")
  assert_eq(second.event_type, "message")
  assert_eq(second.data, "third")
  assert_eq(frames[1].line, 5L)
}

///|
test "SSE removes exactly one initial BOM and decodes partial emoji bytes" {
  let input = @utf8.encode(
    "\uFEFFdata: 🌙\n\n\uFEFFdata: ignored\n\ndata: kept\n\n",
  )
  let frames = decode_sse_for_test(input, 1)
  assert_eq(frames.length(), 2)
  assert_eq(frames[0].frame.unwrap().data, "🌙")
  assert_eq(frames[1].frame.unwrap().data, "kept")
}

///|
test "SSE strips only one space and joins empty data lines" {
  let source = b": note\nevent: one\nid: event-a\nretry: 10\ndata\ndata:  x  \n\nevent: unused\n\n"
  let frames = decode_sse_for_test(source, 6)
  assert_eq(frames.length(), 1)
  assert_eq(frames[0].frame.unwrap().event_type, "one")
  assert_eq(frames[0].frame.unwrap().data, "\n x  ")
}

///|
test "SSE ignores unknown fields and resets event types on empty frames" {
  let frames = decode_sse_for_test(b"event: ping\nunknown\n\ndata:\n\n", 30)
  assert_eq(frames.length(), 1)
  assert_eq(frames[0].frame.unwrap().event_type, "message")
  assert_eq(frames[0].frame.unwrap().data, "")
  assert_eq(frames[0].line, 4L)
}

///|
test "SSE rejects an invalid UTF-8 record and resumes at next frame" {
  let frames = decode_sse_for_test(b"data: \xFF\n\ndata: ok\n\n", 3)
  assert_eq(frames.length(), 2)
  assert_true(frames[0].frame is Err({ "kind": "sse_utf8", .. }))
  assert_eq(frames[1].frame.unwrap().data, "ok")
}

///|
test "SSE caps multibyte lines and accumulated data independently" {
  let combined = b"data: 12345678\ndata: 12345678\n\ndata: ok\n\n"
  let frames = decode_sse_for_test(combined, 8, max_chars=15)
  assert_true(frames[0].frame is Err({ "kind": "sse_event_limit", .. }))
  assert_eq(frames[1].frame.unwrap().data, "ok")
  let too_long = b"data: XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\n\ndata: ok\n\n"
  let frames = decode_sse_for_test(too_long, 2, max_chars=12)
  assert_true(frames[0].frame is Err({ "kind": "sse_event_limit", .. }))
  assert_eq(frames[1].frame.unwrap().data, "ok")
}

///|
test "SSE refuses partial event at EOF with or without terminal LF" {
  for fixture in [b"data: {}", b"data: {}\n"] {
    let frames = decode_sse_for_test(fixture, 1)
    assert_eq(frames.length(), 1)
    assert_true(frames[0].frame is Err({ "kind": "sse_truncated_event", .. }))
  }
}

///|
test "SSE handles pending invalid bytes and event limits at EOF" {
  let frames = decode_sse_for_test(b"data: \xFC\r", 10)
  assert_true(frames[0].frame is Err({ "kind": "sse_utf8", .. }))
  let frames = decode_sse_for_test(
    b"data: very_long_text_without_a_newline",
    8,
    max_chars=8,
  )
  assert_true(frames[0].frame is Err({ "kind": "sse_event_limit", .. }))
}

///|
test "SSE materializes independent completion, choice, and tool indices" {
  let input = chat_for_test("{\"n\":", id="first") +
    chat_for_test("{\"n\":2}", index=1, id="second") +
    chat_for_test("{\"n\":3}", choice=1, id="third") +
    chat_for_test("{\"n\":4}", message_id="other", id="fourth") +
    chat_for_test("9007199254740993}") +
    "data: [DONE]\n\n"
  let (out, status) = run_sse_for_test(input, ["--sse", "--strict-exit"])
  assert_eq(status, 0)
  assert_eq(out.length(), 4)
  assert_true(
    out[0]
    is {
      "call": { "id": "first", "index": 0, .. },
      "json": "{\"n\":9007199254740993}",
      ..
    },
  )
  assert_true(
    out[1]
    is { "call": { "id": "second", "index": 1, .. }, "json": "{\"n\":2}", .. },
  )
  assert_true(
    out[2]
    is {
      "call": { "message_id": "chat", "choice_index": 1, .. },
      "json": "{\"n\":3}",
      ..
    },
  )
  assert_true(
    out[3]
    is {
      "call": { "message_id": "other", "choice_index": 0, .. },
      "json": "{\"n\":4}",
      ..
    },
  )
  assert_true(out[0].stringify().contains("\"value\":{\"n\":9007199254740993}"))
}

///|
test "SSE ignores separate reasoning channels even when text contains braces" {
  let input = sse_for_test({
      "choices": [
        {
          "index": 0,
          "delta": { "content": "{x:1", "reasoning_content": "{y:2" },
        },
      ],
    }) +
    chat_for_test("<tHiNk>{draft:42}</ThInK>{live:true") +
    "data: [DONE]\n\n"
  let (out, status) = run_sse_for_test(input, [
    "--sse", "--ignore-think", "--strict-exit",
  ])
  assert_eq(status, 0)
  assert_eq(out.length(), 1)
  assert_true(out[0] is { "json": "{\"live\":true}", .. })
  assert_true(out[0].stringify().contains("ignore_think_block"))
}

///|
test "SSE completion choice emits final once before DONE" {
  let input = chat_for_test("{\"n\":1}") +
    sse_for_test({
      "choices": [{ "index": 0, "delta": {}, "finish_reason": "tool_calls" }],
    }) +
    "data: [DONE]\n\n"
  let (out, status) = run_sse_for_test(input, ["--sse", "--strict-exit"])
  assert_eq(status, 0)
  assert_eq(out.length(), 1)
  assert_true(
    out[0] is { "event": "tool_call", "finish_reason": "tool_calls", .. },
  )
}

///|
test "SSE DONE seals pending tool calls and ignores subsequent frames" {
  let input = chat_for_test("{}") +
    "data: [DONE]\n\n" +
    chat_for_test("{wrong:true}")
  let (out, status) = run_sse_for_test(input, ["--sse", "--strict-exit"])
  assert_eq(status, 0)
  assert_eq(out.length(), 1)
  assert_true(out[0] is { "finish_reason": "done", "json": "{}", .. })
}

///|
test "SSE EOF finalizes live tool calls and discards partial events" {
  let input = chat_for_test("{\"n\":1") + "data: [DONE]"
  let (out, status) = run_sse_for_test(input, ["--sse", "--strict-exit"])
  assert_eq(status, 1)
  assert_eq(out.length(), 2)
  assert_true(
    out[0]
    is { "event": "error", "error": { "kind": "sse_truncated_event", .. }, .. },
  )
  assert_true(out[1] is { "finish_reason": "eof", "json": "{\"n\":1}", .. })
}

///|
test "SSE emits exact patches and field seal progress" {
  let input = chat_for_test("{\"k/~\":\"he") +
    chat_for_test("llo\"}") +
    "data: [DONE]\n\n"
  let (out, status) = run_sse_for_test(input, [
    "--sse", "--emit-patches", "--strict-exit",
  ])
  assert_eq(status, 0)
  assert_eq(out.length(), 3)
  assert_true(
    out[0]
    is {
      "event": "patch",
      "patches": [{ "op": "replace", "path": "", .. }],
      ..
    },
  )
  assert_true(
    out[0].stringify().contains("\"pointer\":\"/k~1~0\",\"sealed\":false"),
  )
  assert_true(
    out[1]
    is {
      "event": "patch",
      "patches": [{ "op": "replace", "path": "/k~1~0", "value": "hello", .. }],
      ..
    },
  )
  assert_true(
    out[1].stringify().contains("\"pointer\":\"/k~1~0\",\"sealed\":true"),
  )
  assert_true(out[2] is { "event": "tool_call", "patches": [], .. })
}

///|
test "SSE recalculates patches against the coerced report without rounding" {
  let input = chat_for_test("{\"n\":\"900719925474") +
    chat_for_test("0993\"}") +
    "data: [DONE]\n\n"
  let schema : Json = { "properties": { "n": { "type": "integer" } } }
  let flags = [
    "--sse", "--emit-patches", "--strict-exit", "--schema", "ignored", "--coerce",
  ]
  let (out, status) = run_sse_for_test(input, flags, schema~)
  assert_eq(status, 0)
  assert_eq(out.length(), 3)
  assert_true(
    out[1].stringify().contains("\"path\":\"/n\",\"value\":9007199254740993"),
  )
  assert_true(
    out[2] is { "patches": [], "json": "{\"n\":9007199254740993}", .. },
  )
}

///|
test "SSE strict status ignores interim validation while final failures return 3" {
  let source = chat_for_test("{\"x\":true") +
    chat_for_test(",\"n\":1}") +
    "data: [DONE]\n\n"
  let schema : Json = { "required": ["n"] }
  let flags = [
    "--sse", "--emit-patches", "--strict-exit", "--retry-prompt", "--schema", "ignored",
  ]
  let (out, status) = run_sse_for_test(source, flags, schema~)
  assert_eq(status, 0)
  assert_true(out[0] is { "status": 3, "schema": { "valid": false, .. }, .. })
  assert_true(out[2] is { "status": 0, "schema": { "valid": true, .. }, .. })
  let (out, status) = run_sse_for_test(chat_for_test("{}"), flags, schema~)
  assert_eq(status, 3)
  let prompt = out[1].stringify()
  assert_true(prompt.contains("retry_prompt") && prompt.contains("$.n"))
}

///|
test "SSE malformed provider records are isolated and take precedence over schema" {
  let source = "data: ???\n\ndata: []\n\ndata: {\"choices\":0}\n\n" +
    chat_for_test("{}") +
    "data: [DONE]\n\n"
  let schema : Json = { "required": ["n"] }
  let (out, status) = run_sse_for_test(
    source,
    ["--sse", "--strict-exit", "--schema", "ignored"],
    schema~,
  )
  assert_eq(status, 1)
  assert_eq(out.length(), 4)
  assert_true(out[0] is { "error": { "kind": "sse_json", .. }, .. })
  assert_true(out[1] is { "error": { "kind": "sse_payload", .. }, .. })
  assert_true(out[2] is { "error": { "kind": "sse_payload", .. }, .. })
  assert_true(out[3] is { "status": 3, .. })
  let (_, loose) = run_sse_for_test(source, ["--sse"])
  assert_eq(loose, 0)
}

///|
test "SSE rejects unbounded, negative, and fractional provider indices" {
  let invalid : Json = {
    "choices": [
      { "index": -1 },
      { "index": 1.25 },
      { "index": 2147483648 },
      { "index": 0, "delta": { "tool_calls": [{ "function": {} }] } },
    ],
  }
  let (out, status) = run_sse_for_test(sse_for_test(invalid), [
    "--sse", "--strict-exit",
  ])
  assert_eq(status, 1)
  assert_eq(out.length(), 4)
  for record in out {
    assert_true(record is { "error": { "kind": "sse_payload", .. }, .. })
  }
}

///|
test "SSE rejects provider errors without forwarding sensitive payloads" {
  let source = "event: error\ndata: {\"detail\":\"sensitive\"}\n\n"
  let (out, status) = run_sse_for_test(source, ["--sse", "--strict-exit"])
  assert_eq(status, 1)
  assert_true(out[0] is { "error": { "kind": "sse_provider", .. }, .. })
  assert_false(out[0].stringify().contains("sensitive"))
}

///|
test "SSE rejects conflicting call identities and input received after finish" {
  let input = chat_for_test("{", id="a") +
    chat_for_test("}", id="b") +
    chat_for_test("more") +
    "data: [DONE]\n\n"
  let (out, status) = run_sse_for_test(input, ["--sse", "--strict-exit"])
  assert_eq(status, 1)
  assert_eq(out.length(), 2)
  assert_true(out[0] is { "error": { "kind": "sse_call_identity", .. }, .. })
  assert_true(out[1] is { "error": { "kind": "sse_after_finish", .. }, .. })
}

///|
test "SSE does not convert non-string Chat arguments into a fragment" {
  let invalid = sse_for_test({
    "choices": [
      {
        "index": 0,
        "delta": {
          "tool_calls": [
            { "index": 0, "function": { "arguments": { "n": 1 } } },
            { "index": 1, "function": [] },
          ],
        },
      },
    ],
  })
  let (out, status) = run_sse_for_test(invalid + chat_for_test("{}"), [
    "--sse", "--strict-exit",
  ])
  assert_eq(status, 1)
  assert_eq(out.length(), 3)
  assert_true(out[0] is { "error": { "kind": "sse_payload", .. }, .. })
  assert_true(out[1] is { "error": { "kind": "sse_payload", .. }, .. })
  assert_true(out[2] is { "event": "tool_call", "json": "{}", .. })
}

///|
test "SSE Anthropic input deltas replace placeholder and retain metadata" {
  let input = sse_for_test({
      "type": "message_start",
      "message": { "id": "claude-1" },
    }) +
    claude_for_test("content_block_start", 1, {
      "content_block": {
        "type": "tool_use",
        "id": "u0",
        "name": "weather",
        "input": {},
      },
    }) +
    claude_for_test("content_block_delta", 1, {
      "delta": { "type": "thinking_delta", "thinking": "{draft:1" },
    }) +
    claude_for_test("content_block_delta", 1, {
      "delta": { "type": "input_json_delta", "partial_json": "{\"city\":\"上" },
    }) +
    claude_for_test("content_block_delta", 1, {
      "delta": { "type": "input_json_delta", "partial_json": "海🌙\"}" },
    }) +
    claude_for_test("content_block_stop", 1, {}) +
    sse_for_test({ "type": "message_stop" })
  let (out, status) = run_sse_for_test(input, [
    "--sse", "--emit-patches", "--strict-exit",
  ])
  assert_eq(status, 0)
  assert_eq(out.length(), 3)
  assert_true(
    out[2]
    is {
      "event": "tool_call",
      "finish_reason": "content_block_stop",
      "call": {
        "message_id": "claude-1",
        "index": 1,
        "id": "u0",
        "name": "weather",
        ..
      },
      "json": "{\"city\":\"上海🌙\"}",
      ..
    },
  )
}

///|
test "SSE Anthropic initial input is retained on message stop without deltas" {
  let input = "event: content_block_start\r\ndata: {\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"input\":{\"i\":9007199254740993}}}\r\n\r\n" +
    "event: message_stop\ndata: {}\n\n"
  let (out, status) = run_sse_for_test(input, ["--sse", "--strict-exit"])
  assert_eq(status, 0)
  assert_eq(out.length(), 1)
  assert_true(
    out[0]
    is {
      "json": "{\"i\":9007199254740993}",
      "finish_reason": "message_stop",
      ..
    },
  )
}

///|
test "SSE Anthropic ignores non-tool content and reports invalid tool framing" {
  let input = claude_for_test("content_block_start", 0, {
      "content_block": { "type": "thinking" },
    }) +
    claude_for_test("content_block_stop", 0, {}) +
    claude_for_test("content_block_start", 1, {
      "content_block": { "type": "tool_use", "input": [] },
    }) +
    claude_for_test("content_block_delta", 2, {
      "delta": { "type": "input_json_delta", "partial_json": false },
    }) +
    sse_for_test({ "type": "content_block_stop" })
  let (out, status) = run_sse_for_test(input, ["--sse", "--strict-exit"])
  assert_eq(status, 1)
  assert_eq(out.length(), 3)
  for record in out {
    assert_true(
      record is { "event": "error", "error": { "kind": "sse_payload", .. }, .. },
    )
  }
}

///|
test "SSE gateway bounds call identities across a provider stream" {
  let calls = StringBuilder()
  for i in 0..<(sse_max_calls + 1) {
    calls.write_string(chat_for_test("{}", index=i))
  }
  let (out, status) = run_sse_for_test(calls.to_string(), [
    "--sse", "--strict-exit",
  ])
  assert_eq(status, 1)
  assert_eq(out.length(), sse_max_calls + 1)
  assert_true(out[0] is { "error": { "kind": "sse_call_limit", .. }, .. })
}

///|
test "SSE rejects rounded fractional identity numbers and invalid deltas" {
  let input = "data: {\"choices\":[{\"index\":2147483647.0000001},{\"index\":2e0},{\"index\":0,\"delta\":[]}]}\n\n"
  let (out, status) = run_sse_for_test(input, ["--sse", "--strict-exit"])
  assert_eq(status, 1)
  assert_eq(out.length(), 3)
  for record in out {
    assert_true(record is { "error": { "kind": "sse_payload", .. }, .. })
  }
}

///|
test "SSE refuses oversized identity metadata without retaining calls" {
  let long = "a".repeat(sse_max_metadata_units + 1)
  let input = chat_for_test("{}", id=long) +
    chat_for_test("{}", name=long) +
    chat_for_test("{}", message_id=long) +
    sse_for_test({
      "type": "message_start",
      "message": { "id": Json::string(long) },
    }) +
    chat_for_test("{}", id="valid")
  let (out, status) = run_sse_for_test(input, ["--sse", "--strict-exit"])
  assert_eq(status, 1)
  assert_eq(out.length(), 5)
  for i in 0..<4 {
    assert_true(out[i] is { "error": { "kind": "sse_metadata_limit", .. }, .. })
  }
  assert_true(
    out[4] is { "event": "tool_call", "call": { "id": "valid", .. }, .. },
  )
}

///|
test "SSE a changed tool name cannot reinterpret earlier call arguments" {
  let input = chat_for_test("{", name="lookup") +
    chat_for_test("}", name="write") +
    "data: [DONE]\n\n"
  let (out, status) = run_sse_for_test(input, ["--sse", "--strict-exit"])
  assert_eq(status, 1)
  assert_eq(out.length(), 1)
  assert_true(
    out[0]
    is {
      "call": { "name": "lookup", .. },
      "error": { "kind": "sse_call_identity", .. },
      ..
    },
  )
}

///|
test "SSE Anthropic message_stop is terminal and finalizes pending input" {
  let input = claude_for_test("content_block_delta", 1, {
      "delta": { "type": "input_json_delta", "partial_json": "{\"live\":true" },
    }) +
    sse_for_test({ "type": "message_stop" }) +
    claude_for_test("content_block_delta", 2, {
      "delta": { "type": "input_json_delta", "partial_json": "{}" },
    })
  let (out, status) = run_sse_for_test(input, ["--sse", "--strict-exit"])
  assert_eq(status, 0)
  assert_eq(out.length(), 1)
  assert_true(
    out[0]
    is {
      "event": "tool_call",
      "finish_reason": "message_stop",
      "json": "{\"live\":true}",
      ..
    },
  )
}
