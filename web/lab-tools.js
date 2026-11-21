"use strict";

function latencyLine(series, max, steps) {
  return series.map((value, index) => {
    const x = index * 720 / Math.max(1, steps - 1);
    const y = 96 - value * 92 / max;
    return x.toFixed(2) + "," + y.toFixed(2);
  }).join(" ");
}

function showLatency(samples, steps) {
  const max = Math.max(1, ...samples[0], ...samples[1]);
  elements["latency-incremental"].setAttribute("points", latencyLine(samples[0], max, steps));
  elements["latency-reference"].setAttribute("points", latencyLine(samples[1], max, steps));
  labSet(elements["latency-range"], "Shared scale 0–{0} µs", max.toFixed(1));
  elements["latency-progress"].max = steps;
  elements["latency-progress"].value = samples[0].length;
}

async function measureStreamLatency() {
  const button = elements["latency-run"];
  const width = Number(elements["latency-chunk"].value);
  const engine = activeEngine;
  const engineName = engine === wasmEngine ? "Wasm GC" : "MoonBit JS";
  const samples = [[], []];
  const steps = Math.ceil(writeFileInput.length / width);
  const status = elements["latency-state"];
  let running = false;
  button.disabled = true;
  elements["latency-chunk"].disabled = true;
  labSet(status, "{0} · Measuring…", engineName);
  showLatency(samples, steps);
  try {
    await nextFrame();
    engine.benchStart();
    running = true;
    for (let offset = 0, index = 0; offset < writeFileInput.length; offset += width, index++) {
      const chunk = writeFileInput.slice(offset, offset + width);
      // Alternate order so either lane has the same opportunity to run first.
      for (let lane = index % 2, run = 0; run < 2; lane = 1 - lane, run++) {
        const started = performance.now();
        const accepted = engine.benchStep(chunk, lane === 1);
        const duration = (performance.now() - started) * 1_000;
        if (!accepted) throw new Error("The benchmark could not append a chunk.");
        samples[lane].push(duration);
      }
      if (!engine.benchMatches()) throw Object.assign(new Error("Snapshot mismatch at chunk {0}."), { chunk: index + 1 });
      if ((index + 1) % 12 === 0) {
        showLatency(samples, steps);
        await nextFrame();
      }
    }
    const finished = engine.benchFinish();
    running = false;
    if (!finished) throw new Error("The final documents did not match.");
    showLatency(samples, steps);
    const [incremental, reference] = samples.map(series => series.reduce((total, value) => total + value, 0));
    labBind(status, () => labText("{0} · {1} snapshots matched · {2} ms incremental · {3} ms reference",
      engineName, steps, (incremental / 1_000).toFixed(2), (reference / 1_000).toFixed(2)) +
      (incremental > 0 ? labText(" · {0}× reference/incremental", (reference / incremental).toFixed(2)) : ""));
  } catch (error) {
    labBind(status, () => labText("Benchmark stopped. {0}", Object.hasOwn(labChinese, error.message)
      ? labText(error.message, error.chunk) : labEngineMessage(error.message, "Unable to repair")));
    if (running) engine.benchFinish();
  } finally {
    button.disabled = false;
    elements["latency-chunk"].disabled = false;
  }
}

function moonbitString(text) {
  let literal = '"';
  const escaped = { '"': '\\"', "\\": "\\\\", "\r": "\\r", "\n": "\\n", "\t": "\\t" };
  for (const char of text) {
    const point = char.codePointAt(0);
    literal += escaped[char] ?? (point < 32 || point === 127 || (point >= 0xD800 && point <= 0xDFFF)
      ? "\\u" + point.toString(16).padStart(4, "0") : char);
  }
  return literal + '"';
}

function pwshString(text) {
  // PowerShell also treats typographic apostrophes as quote delimiters.
  return "'" + text.replace(/['\u2018\u2019]/g, "$&$&") + "'";
}

function snippetComment(message) {
  return typeof labText === "function" ? labText(message) : message;
}

function moonbitSnippet(source, schema, { json5, coerce, extract, ignoreThink, mcp, semantic, diagnostics, chinese }) {
  const program = [
    snippetComment('// moon.pkg imports "ZSY2221/json_repair" @repair and "moonbitlang/core/json".'),
    "fn main {",
    "  let source = " + moonbitString(source),
    "  let policy : @repair.RepairPolicy = {",
    "    options: { ..@repair.RepairOptions::default(), json5: " + json5 + " },",
    "    ignore_think_blocks: " + ignoreThink + ",",
    "  }",
  ];
  if (schema || mcp) {
    program.push("  let schema_text = " + moonbitString(schema || "{}"));
    program.push("  let schema = try! @json.parse(schema_text[:], preserve_number_repr=true, reject_duplicate_keys=true)");
  }
  if (mcp) {
    program.push(
      "  let registry = @repair.ToolSchemaRegistry::from_json(schema).unwrap()",
      "  let result = @repair.guard_mcp_tool_call(source, registry, policy~, coerce=" + coerce + ")",
      "  if result.frame is Some(frame) { println(frame) }",
    );
  } else {
    if (extract) {
      program.push(
        "  let blocks = @repair.extract_all_with_policy(source, policy).unwrap()",
        "  for block in blocks {",
        "    let report = block.report",
      );
    } else {
      program.push("  let report = @repair.repair_with_policy(source, policy).unwrap()");
    }
    const indent = extract ? "    " : "  ";
    const language = ", chinese=" + Boolean(chinese);
    if (diagnostics) {
      program.push(indent + "println(@repair.render_repair_audit(source, report.edits" + language + "))");
    }
    if (schema && coerce) {
      if (semantic) {
        program.push(indent + "let result = @repair.coerce_with_schema_semantic(report.value, schema)");
      } else {
        program.push(
          indent + "let result = @repair.coerce_with_schema(report.value, schema, options={",
          indent + "  number_strings: true, boolean_strings: true, wrap_scalar_arrays: true,",
          indent + "})",
        );
      }
      program.push(
        indent + "println(result.json)",
        indent + "println(@json.to_json(result.errors).stringify())",
      );
    } else {
      program.push(indent + "println(report.json)");
      if (schema) program.push(indent + "println(@json.to_json(@repair.validate(report.value, schema)).stringify())");
    }
    if (extract) program.push("  }");
  }
  return [...program, "}"].join("\n");
}

function cliSnippet(source, schema, { json5, coerce, extract, ignoreThink, mcp, semantic, diagnostics }) {
  const program = [
    snippetComment("# Run from the project root in PowerShell."),
    '$labDir = Join-Path ([IO.Path]::GetTempPath()) ("moon-repair-" + [Guid]::NewGuid().ToString("N"))',
    "New-Item -ItemType Directory -Path $labDir | Out-Null",
    "$labRequest = Join-Path $labDir 'request.json'",
  ];
  const flags = [];
  if (mcp) {
    program.push(snippetComment("# The input file holds one JSON-RPC frame per line."));
    flags.push("--mcp-guard", "--tool-schemas", "$labSchema", "--strict-exit");
  } else {
    if (schema) flags.push("--schema", "$labSchema");
    if (extract) flags.push("--extract-all");
    if (diagnostics) flags.push("--diagnostic-format", "pretty");
    if (schema && coerce && semantic) program.unshift(snippetComment("# Use the MoonBit example for semantic coercion."));
  }
  if (ignoreThink) flags.push("--ignore-think");
  if (json5) flags.push("--json5");
  if (coerce && (schema || mcp)) flags.push("--coerce");
  const write = (variable, content) => "[IO.File]::WriteAllText(" + variable + ", " + pwshString(content) + ")";
  program.push(write("$labRequest", source));
  if (schema || mcp) {
    program.push("$labSchema = Join-Path $labDir 'schema.json'", write("$labSchema", schema || "{}"));
  }
  program.push(["moon run --target native cmd/main --", ...flags, "$labRequest"].join(" "));
  return program.join("\n");
}

function refreshCodeSnippets() {
  if (!elements["code-card"].open) return;
  const [json5, coerce, extract, ignoreThink] = repairOptions();
  const settings = {
    json5, coerce, extract, ignoreThink,
    mcp: elements["enable-mcp"].checked,
    semantic: elements["enable-semantic"].checked,
    diagnostics: elements["enable-diagnostics"].checked,
    chinese: labLanguage === "zh",
  };
  const input = playback?.target ?? elements.source.value;
  const schema = elements.schema.value;
  const blocked = playback ? playbackBudget(playback, schema) : inspectLabInput(input, schema);
  if (blocked) {
    labSet(elements["moonbit-code"], "Shorten the input or select a preset to continue.");
    labSet(elements["cli-code"], "Shorten the input or select a preset to continue.");
  } else {
    labClear(elements["moonbit-code"]);
    labClear(elements["cli-code"]);
    elements["moonbit-code"].textContent = moonbitSnippet(input, schema.trim(), settings);
    elements["cli-code"].textContent = cliSnippet(input, schema.trim(), settings);
  }
  elements["copy-moonbit"].disabled = Boolean(blocked);
  elements["copy-cli"].disabled = Boolean(blocked);
  labSet(elements["copy-moonbit"], "Copy MoonBit");
  labSet(elements["copy-cli"], "Copy PowerShell");
}

function connectLabTools() {
  elements["latency-run"].addEventListener("click", measureStreamLatency);
  elements["code-card"].addEventListener("toggle", refreshCodeSnippets);
  for (const language of ["moonbit", "cli"]) {
    elements["copy-" + language].addEventListener("click", async () => {
      const snippet = elements[language + "-code"];
      const copied = await copyText(snippet.textContent, snippet);
      labSet(elements["copy-" + language], copied ? "Copied" : "Text selected");
    });
  }
}
