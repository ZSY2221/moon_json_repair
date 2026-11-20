///|
/// Adapts the repair and validation APIs for the local browser playground.
#export_name("moonRepairPayload")
pub fn run_payload(source : String, schema_text : String) -> String {
  let outcome : Json = match @repair.repair(source) {
    Err(error) => { "ok": false, "error": @json.to_json(error) }
    Ok(report) => {
      let validation : Json = if schema_text == "" {
        { "state": "skipped" }
      } else {
        try {
          let schema = @json.parse(
            schema_text[:],
            preserve_number_repr=true,
            reject_duplicate_keys=true,
          )
          {
            "state": "checked",
            "errors": @json.to_json(@repair.validate(report.value, schema)),
          }
        } catch {
          error => { "state": "invalid_json", "message": error.to_string() }
        }
      }
      { "ok": true, "report": @json.to_json(report), "validation": validation }
    }
  }
  outcome.stringify()
}
