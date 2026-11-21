///|
priv struct ThinkFuzz {
  mut state : UInt32
}

///|
fn ThinkFuzz::pick(self : ThinkFuzz, bound : Int32) -> Int32 {
  let mut n = self.state
  n = n ^ (n << 13)
  n = n ^ (n >> 17)
  n = n ^ (n << 5)
  self.state = n
  (n % bound.reinterpret_as_uint()).reinterpret_as_int()
}

///|
fn ThinkFuzz::tag(self : ThinkFuzz, closing : Bool) -> String {
  let text = StringBuilder()
  text.write_string(if closing { "</" } else { "<" })
  for i in 0..<5 {
    let spelling : StringView = if self.pick(2) == 0 {
      "THINK"
    } else {
      "think"
    }
    text.write_char(char_at(spelling, i))
  }
  text.write_char('>')
  text.to_string()
}

///|
fn ThinkFuzz::sample(self : ThinkFuzz) -> String {
  let out = StringBuilder()
  let depths = self.pick(3) + 2
  let fragments : Array[String] = [
    "plain <ThI typo> []",
    (
      #|{"message":"escaped \"<ThInK> and literal </think>","next":['</THINK>',2]}
    ),
    (
      #|{draft:'escaped \'<THINK> and literal </think>',next:["<Think>",true]}
    ),
    "{\"draft\":\"literal\n</ThInK>\nstill inside\"}",
    "{draft:'literal\r\n</ThInK>\r\nstill inside'}",
    "{\"next\":[/* </think> */ false, 0]}",
  ]
  for _ in 0..<depths {
    out.write_string(self.tag(false))
    out.write_string(fragments[self.pick(fragments.length())])
    out.write_string(if self.pick(2) == 0 { "\n" } else { "\r\n" })
  }
  let mut remaining = depths
  if self.pick(2) == 0 {
    let quotes = if self.pick(2) == 0 { ['"', '\''] } else { ['\'', '"'] }
    for quote in quotes {
      out.write_string("{draft:")
      out.write_char(quote)
      if self.pick(2) == 0 {
        out.write_char('\\')
        out.write_char(quote)
      }
      out.write_string("unfinished")
      out.write_string(if self.pick(2) == 0 { "\n" } else { "\r\n" })
      out.write_string(self.tag(true))
      out.write_string(if self.pick(2) == 0 { " \t\n" } else { "\r\n" })
    }
    remaining -= quotes.length()
    if remaining > 0 {
      // These unescaped quote boundaries resolve both earlier guards while
      // the resumed path is still inside the outer reasoning block.
      out.write_string("{\"probe\":\"'body\"}\n")
    }
  }
  let closers = if remaining > 0 && self.pick(5) == 0 {
    self.pick(remaining)
  } else {
    remaining
  }
  for _ in 0..<closers {
    out.write_string(self.tag(true))
    out.write_string(if self.pick(2) == 0 { "\n" } else { "\r\n" })
  }
  let payload =
    #|{"id":9007199254740993,"home/~": ["'literal <ThInK>",{"exact":-1.2300e+17,"note":"\uD83D\uDE00"}]}
  let end = if self.pick(3) == 0 {
    self.pick(payload.length() + 1)
  } else {
    payload.length()
  }
  out.write_string(payload.unsafe_substring(start=0, end~))
  out.to_string()
}

///|
// Compare number tokens exactly while ignoring object member order.
fn exact_recovery_value(left : Json, right : Json) -> Bool {
  match (left, right) {
    (Object(a), Object(b)) => {
      if a.length() != b.length() {
        return false
      }
      for name, child in a {
        guard b.get(name) is Some(other) && exact_recovery_value(child, other) else {
          return false
        }
      }
      true
    }
    (Array(a), Array(b)) => {
      if a.length() != b.length() {
        return false
      }
      for i in 0..<a.length() {
        if !exact_recovery_value(a[i], b[i]) {
          return false
        }
      }
      true
    }
    _ => left.stringify() == right.stringify()
  }
}

///|
fn check_think_recovery_samples(seed : UInt32) -> Unit raise {
  let rng : ThinkFuzz = { state: seed, }
  for sample in 0..<200 {
    let source = rng.sample()
    let options = { ..RepairOptions::default(), json5: rng.pick(2) == 0, }
    let policy = options.with_ignore_think_blocks(true)
    let stream = RepairStream::with_policy(policy)
    let mut applied = Json::null()
    let mut at = 0
    while at < source.length() {
      let end = (at + 1 + rng.pick(21)).min(source.length())
      let prefix = source.unsafe_substring(start=0, end~)
      stream.push(source.unsafe_substring(start=at, end~)).unwrap()
      let context = "seed \{seed}, sample \{sample}, offset \{end}: \{prefix}"
      assert_eq(
        stream.status(),
        reference_think_status(prefix, options),
        msg=context,
      )
      assert_eq(stream.scanned_units(), end, msg=context)
      if stream.next_patches() is Ok(frame) {
        applied = apply_json_patches(applied, frame.patches[:]).unwrap()
        assert_true(
          exact_recovery_value(applied, frame.report.value),
          msg=context,
        )
      }
      at = end
    }
    let finalized = stream.finalize()
    assert_eq(finalized, repair_with_policy(source, policy), msg=source)
    if finalized is Ok(report) {
      let strict = @json.parse(
        report.json[:],
        preserve_number_repr=true,
        reject_duplicate_keys=true,
      )
      assert_true(exact_recovery_value(applied, strict), msg=source)
      let second = repair_with_policy(report.json, policy).unwrap()
      assert_eq(second.json, report.json, msg=source)
      assert_true(second.edits.is_empty(), msg=source)
    }
  }
}

///|
test "seeded nested reasoning recovery, framing and exact Patch replay 3681277199" {
  check_think_recovery_samples(3681277199U)
}

///|
test "seeded nested reasoning recovery, framing and exact Patch replay 285640487" {
  check_think_recovery_samples(285640487U)
}
