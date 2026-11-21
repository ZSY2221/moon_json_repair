///|
fn main {
  let input =
    #|<think>Draft account lookup</think>{"userName":"Ada 🙂","order_id":"9007199254740993","currency":" usd ","amount_cents":-25
  let policy = @repair.RepairOptions::default().with_ignore_think_blocks(true)
  let report = @repair.repair_with_policy(input, policy).unwrap()
  let schema : Json = {
    "type": "object",
    "required": ["user_name", "order_id", "currency", "amount_cents"],
    "properties": {
      "user_name": { "type": "string" },
      "order_id": { "type": "integer" },
      "currency": { "enum": ["USD", "EUR"] },
      "amount_cents": { "type": "integer", "minimum": 1 },
    },
  }
  let checked = @repair.coerce_with_schema_semantic(report.value, schema)
  println(checked.json)
  for error in checked.errors {
    println(
      @repair.render_diagnostic(
        checked.json,
        @repair.SourceDiagnostic::Schema(error),
      ),
    )
  }
  if !checked.errors.is_empty() {
    println(checked.format_retry_prompt(schema))
  }
}
