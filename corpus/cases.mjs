// Hand-curated reproductions of recurring LLM output failure shapes. No logs or PII.
const amountSchema = {
  type: "object",
  required: ["args"],
  properties: {
    args: {
      type: "object",
      required: ["amount"],
      properties: { amount: { type: "number", minimum: 0 } },
    },
  },
};

export const corpus = [
  {
    id: "think-draft-before-tool", group: "reasoning", ignoreThink: true, ignored: 1,
    source: '<think>{tool:"draft"}</think>\nFinal {"tool":"ship","args":{"id":1}}',
    output: ['{"tool":"ship","args":{"id":1}}'],
  },
  {
    id: "think-upper-crlf-fence", group: "reasoning", ignoreThink: true, ignored: 1,
    source: '<THINK>🌙\r\n{"draft":1}\r\n</ThInK>\r\n```json\r\n{"tool":"reserve"}\r\n```',
    output: ['{"tool":"reserve"}'],
  },
  {
    id: "think-tag-in-string", group: "reasoning", ignoreThink: true, ignored: 0,
    source: '{"tool":"echo","args":{"text":"say <think>{draft}</think> literally"}}',
    output: ['{"tool":"echo","args":{"text":"say <think>{draft}</think> literally"}}'],
  },
  {
    id: "think-open-only", group: "reasoning", ignoreThink: true,
    source: '<think>Working on {"tool":"should_not_execute"}',
    error: "empty_input",
  },
  {
    id: "think-open-tail", group: "reasoning", ignoreThink: true, extract: true, ignored: 1,
    source: '{"tool":"ready"}\n<think>{"tool":"never"}',
    output: ['{"tool":"ready"}'],
  },
  {
    id: "think-nested-then-two-tools", group: "reasoning", ignoreThink: true, extract: true, ignored: 1,
    source: '<think>outer <think>{"tool":"scratch"}</think> done</think>\n{"tool":"first"}{"tool":"second"}',
    output: ['{"tool":"first"}', '{"tool":"second"}'],
  },
  {
    id: "think-quoted-close", group: "reasoning", ignoreThink: true, ignored: 1,
    source: '<think>{"text":"keep </think> in scratch","tool":"never"}</think>\n{"tool":"actual"}',
    output: ['{"tool":"actual"}'],
  },
  {
    id: "fence-inline-backticks", group: "format", source: '```json\n{"tool":"echo","text":"A `token` and ```"}\n```',
    output: ['{"tool":"echo","text":"A `token` and ```"}'],
  },
  {
    id: "format-numbered-prose", group: "format",
    source: '1. Here is the JSON you requested:\n{"tool":"travel","args":{"city":"Xi’an"}}',
    output: ['{"tool":"travel","args":{"city":"Xi’an"}}'],
  },
  {
    id: "format-python-literals", group: "format",
    source: "{'tool':'config','args':{'notify':True,'paused':False,'owner':None,},}",
    output: ['{"tool":"config","args":{"notify":true,"paused":false,"owner":null}}'],
  },
  {
    id: "format-comments", group: "format",
    source: '{// default\n"tool":"ping","args":{/* kept */"attempt":2,},}',
    output: ['{"tool":"ping","args":{"attempt":2}}'],
  },
  {
    id: "format-newline-curly-text", group: "format",
    source: '{"tool":"say","line":"他说“好的”\n然后离开"}',
    output: ['{"tool":"say","line":"他说“好的”\\n然后离开"}'],
  },
  {
    id: "format-curly-key-delimiters", group: "format",
    source: '{“tool”:“ping”}', error: "unexpected_token",
  },
  {
    id: "format-bare-key-missing-comma", group: "format",
    source: "{tool:'search' args:{query:'Moon'}}",
    output: ['{"tool":"search","args":{"query":"Moon"}}'],
  },
  {
    id: "stream-concatenated-tools", group: "stream", extract: true,
    source: '{"tool":"prepare"}{"tool":"run","args":{"times":2}}',
    output: ['{"tool":"prepare"}', '{"tool":"run","args":{"times":2}}'],
  },
  {
    id: "stream-truncated-array", group: "stream",
    source: '{"tool":"names","args":{"tags":["a","b',
    output: ['{"tool":"names","args":{"tags":["a","b"]}}'],
  },
  {
    id: "stream-emoji-at-complete-unit-boundary", group: "stream",
    source: '{"tool":"echo","text":"hi 🌙',
    output: ['{"tool":"echo","text":"hi 🌙"}'],
  },
  {
    id: "stream-truncated-utf16-pair", group: "stream",
    source: '{"tool":"echo","text":"🌙'.slice(0, -1),
    error: "invalid_unicode",
  },
  {
    id: "stream-too-deep", group: "stream",
    source: "[".repeat(140) + "0" + "]".repeat(140), error: "depth_limit",
  },
  {
    id: "stream-incomplete-literal", group: "stream",
    source: '{"tool":"send","args":{"ready":tru',
    output: ['{"tool":"send","args":{"ready":true}}'],
  },
  {
    id: "number-safe-integer-boundary", group: "number",
    source: '{"tool":"save","id":9007199254740993}',
    output: ['{"tool":"save","id":9007199254740993}'],
  },
  {
    id: "number-hex-and-leading-dot", group: "number", json5: true,
    source: '{"id":0x20000000000001,"ratio":.5}',
    output: ['{"id":9007199254740993,"ratio":0.5}'],
  },
  {
    id: "number-negative-zero", group: "number",
    source: '{"delta":-0}', output: ['{"delta":-0}'],
  },
  {
    id: "number-exponent-lexeme", group: "number",
    source: '{"price":1e-0008}', output: ['{"price":1e-0008}'],
  },
  {
    id: "number-regular-no-change", group: "number",
    source: '{"tool":"count","amount":42.5,"ok":true}',
    output: ['{"tool":"count","amount":42.5,"ok":true}'],
  },
  {
    id: "schema-coerce-decimal", group: "schema", coerce: true, schema: amountSchema,
    source: '{"tool":"pay","args":{"amount":"42.5"}}',
    output: ['{"tool":"pay","args":{"amount":42.5}}'], errors: [], coercions: ["$.args.amount"],
  },
  {
    id: "schema-boundary-negative", group: "schema", schema: amountSchema,
    source: '{"tool":"pay","args":{"amount":-1}}',
    output: ['{"tool":"pay","args":{"amount":-1}}'], errors: [["$.args.amount", "minimum"]], retry: "$.args.amount",
  },
  {
    id: "schema-enum-currency", group: "schema",
    schema: { properties: { currency: { enum: ["SGD", "USD"] } } },
    source: '{"currency":"`C"}', output: ['{"currency":"`C"}'],
    errors: [["$.currency", "enum"]], retry: "$.currency",
  },
  {
    id: "schema-array-index", group: "schema",
    schema: { properties: { items: { type: "array", items: { type: "integer" } } } },
    source: '{"items":[false]}', output: ['{"items":[false]}'],
    errors: [["$.items[0]", "type"]], retry: "$.items[0]",
  },
  {
    id: "schema-required-field", group: "schema", schema: amountSchema,
    source: '{"tool":"pay","args":{}}', output: ['{"tool":"pay","args":{}}'],
    errors: [["$.args.amount", "required"]], retry: "$.args.amount",
  },
  {
    id: "schema-single-record-array", group: "schema", coerce: true,
    schema: { properties: { tags: { type: "array", items: { type: "string" } } } },
    source: '{"tags":"nightly"}', output: ['{"tags":["nightly"]}'],
    errors: [], coercions: ["$.tags"],
  },
  {
    id: "schema-capitalized-string-not-coerced", group: "schema", coerce: true,
    schema: { properties: { approved: { type: "boolean" } } },
    source: '{"approved":"True"}', output: ['{"approved":"True"}'],
    errors: [["$.approved", "type"]], retry: "$.approved",
  },
  {
    id: "guard-duplicate-tool-key", group: "guard",
    source: '{"tool":"prepare","tool":"commit"}', error: "duplicate_key",
  },
  {
    id: "guard-missing-value", group: "guard",
    source: '{"tool":}', error: "unexpected_token",
  },
  {
    id: "reasoning-nested-before-arguments", group: "reasoning", ignoreThink: true, ignored: 1,
    source: "<think>{guess:1}<ThInK>[false]</tHiNk></think>\r\n{tool:'locate',args:{query:'月亮'}}",
    output: ['{"tool":"locate","args":{"query":"月亮"}}'],
  },
  {
    id: "reasoning-after-completed-call", group: "reasoning", ignoreThink: true, ignored: 1,
    source: '{"ready":true}\n<think>{"draft":false',
    output: ['{"ready":true}'],
  },
  {
    id: "stream-final-key-without-value", group: "stream",
    source: '{"tool":"echo","retry":',
    output: ['{"tool":"echo"}'],
  },
  {
    id: "stream-low-code-unit", group: "stream",
    source: '{"text":"\udc00"}', error: "invalid_unicode",
  },
  {
    id: "stream-assembled-array-arguments", group: "stream",
    source: '{"calls":[{"tool":"one"},{"tool":"two"',
    output: ['{"calls":[{"tool":"one"},{"tool":"two"}]}'],
  },
  {
    id: "format-comment-between-two-members", group: "format",
    source: '{"name":"lookup",/* ignored metadata */ id:42,}',
    output: ['{"name":"lookup","id":42}'],
  },
  {
    id: "number-beyond-uint64", group: "number",
    source: '{"sequence":18446744073709551617}',
    output: ['{"sequence":18446744073709551617}'],
  },
  {
    id: "number-preserve-pricing-precision", group: "number",
    source: '{"amount":0.100000000000000000000001}',
    output: ['{"amount":0.100000000000000000000001}'],
  },
  {
    id: "schema-coerce-wide-id", group: "schema", coerce: true,
    schema: { properties: { id: { type: "integer" } } },
    source: '{"id":"9007199254740993"}',
    output: ['{"id":9007199254740993}'], errors: [], coercions: ["$.id"],
  },
  {
    id: "guard-two-competing-top-level-calls", group: "guard",
    source: '{"tool":"draft"}{"tool":"execute"}', error: "trailing_content",
  },
];
