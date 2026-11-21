///|
priv struct LabBenchmarkLane {
  stream : @repair.RepairStream
  mut preview : Result[@repair.RepairReport, @repair.RepairError]?
  mut patches : Result[@repair.PatchFrame, @repair.RepairError]?
}

///|
fn LabBenchmarkLane::new(stream : @repair.RepairStream) -> LabBenchmarkLane {
  { stream, preview: None, patches: None, }
}

///|
let lab_benchmark_lanes : @ref.Ref[(LabBenchmarkLane, LabBenchmarkLane)?] = @ref.Ref(
  None,
)

///|
/// Start an isolated pair of streams with the same repair policy and fresh
/// patch histories. The reference lane runs the whole-prefix parser.
#export_name("moonLabBenchStart")
pub fn lab_bench_start() -> Unit {
  let policy = @repair.RepairPolicy::default()
  lab_benchmark_lanes.val = Some(
    (
      LabBenchmarkLane::new(@repair.RepairStream::with_policy(policy)),
      LabBenchmarkLane::new(@repair.RepairStream::with_uncached_policy(policy)),
    ),
  )
}

///|
/// Append a chunk and run both snapshot APIs in the chosen benchmark lane.
/// Keep the result for an untimed, exact cross-check.
#export_name("moonLabBenchStep")
pub fn lab_bench_step(chunk : String, reference : Bool) -> Bool {
  guard lab_benchmark_lanes.val is Some((incremental, uncached)) else {
    return false
  }
  let lane = if reference { uncached } else { incremental }
  guard lane.stream.push(chunk) is Ok(_) else { return false }
  lane.preview = Some(lane.stream.preview())
  lane.patches = Some(lane.stream.next_patches())
  true
}

///|
/// Verify both lanes produced the same JSON, diagnostics, edits, patch
/// sequence and field seals. Reports also compare the exact wire spelling.
#export_name("moonLabBenchMatches")
pub fn lab_bench_matches() -> Bool {
  guard lab_benchmark_lanes.val is Some((incremental, uncached)) else {
    return false
  }
  if incremental.preview is None || incremental.preview != uncached.preview {
    return false
  }
  match (incremental.patches, uncached.patches) {
    (Some(Ok(left)), Some(Ok(right))) =>
      left.report == right.report &&
      left.fields == right.fields &&
      @json.to_json(left.patches).stringify() ==
      @json.to_json(right.patches).stringify()
    (Some(Err(left)), Some(Err(right))) => left == right
    _ => false
  }
}

///|
/// Verify the two lanes agree on a successful repaired document at EOF and
/// release their independent stream buffers.
#export_name("moonLabBenchFinish")
pub fn lab_bench_finish() -> Bool {
  guard lab_benchmark_lanes.val is Some((incremental, uncached)) else {
    return false
  }
  lab_benchmark_lanes.val = None
  match (incremental.stream.finalize(), uncached.stream.finalize()) {
    (Ok(left), Ok(right)) => left == right
    _ => false
  }
}

///|
/// Validate one MCP JSON-RPC frame with a tool-name-to-schema JSON registry.
/// Keep the wire payload as a string so browser display preserves large IDs.
#export_name("moonLabGuardMcp")
pub fn lab_guard_mcp(
  source : String,
  registry_text : String,
  json5 : Bool,
  coerce : Bool,
  ignore_think : Bool,
) -> String {
  let settings = if registry_text == "" { "{}" } else { registry_text }
  let schema = @json.parse(
    settings[:],
    preserve_number_repr=true,
    reject_duplicate_keys=true,
  ) catch {
    error => {
      let failure : Json = { "registry_error": error.to_string() }
      return failure.stringify()
    }
  }
  match @repair.ToolSchemaRegistry::from_json(schema) {
    Err(error) => {
      let failure : Json = { "registry_error": error.message }
      failure.stringify()
    }
    Ok(registry) =>
      @json.to_json(
        @repair.guard_mcp_tool_call(
          source,
          registry,
          policy=lab_policy(json5, ignore_think),
          coerce~,
        ),
      ).stringify()
  }
}
