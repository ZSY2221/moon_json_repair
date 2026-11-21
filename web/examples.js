"use strict";

const toolSchema = (tool, properties) => ({
  type: "object",
  required: ["tool", "args"],
  properties: {
    tool: { type: "string", enum: [tool] },
    args: { type: "object", required: Object.keys(properties), properties },
  },
});

const writeFileSchema = {
  path: { type: "string", minLength: 1 },
  content: { type: "string" },
};

function writeFilePayload() {
  let code = "// Generated JavaScript modules for the stream benchmark.\n";
  for (let index = 0; ; index++) {
    const line = 'export const entry' + index + ' = {name: "item", path: "./item.js"};\n';
    if (code.length + line.length + 2 > 50_000) break;
    code += line;
  }
  code += "//" + " ".repeat(50_000 - code.length - 2);
  const frame = JSON.stringify({
    tool: "write_file",
    args: { path: "generated.js", content: code },
  });
  // The source finishes in the value string, like a real interrupted tool call.
  return frame.slice(0, -3);
}

const writeFileInput = writeFilePayload();
const mcpRegistry = {
  write_file: {
    type: "object",
    required: ["path", "content"],
    properties: writeFileSchema,
  },
};

function truncatedMcpCall(argumentsText) {
  return '{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":' +
    '{"name":"write_file","arguments":' + JSON.stringify(argumentsText);
}

const examples = [
  {
    label: "Stream cut",
    group: "stream",
    description: "Recover a tool call that ends inside a string.",
    input: `{
  "tool": "create_ticket",
  "args": {
    "priority": "high",
    "retries": 2,
    "title": "Investigate checkout timeout`,
    schema: toolSchema("create_ticket", {
      priority: { enum: ["low", "normal", "high"] },
      retries: { type: "integer", minimum: 0, maximum: 5 },
      title: { type: "string", minLength: 8 },
    }),
  },
  {
    label: "Markdown & prose",
    group: "stream",
    description: "Extract the JSON payload from surrounding prose and a code fence.",
    input: "Here's the tool call I would use.\n\n```json\n" +
      '{"tool":"search_docs","args":{"query":"MoonBit JSON repair","limit":3}}\n```\n' +
      "I'll wait for those results.",
    schema: toolSchema("search_docs", {
      query: { type: "string", minLength: 1 },
      limit: { type: "integer", minimum: 1, maximum: 10 },
    }),
  },
  {
    label: "Python & JS literals",
    group: "stream",
    description: "Normalize non-JSON literals such as True, None, and undefined.",
    input: `{"tool":"set_preferences","args":{
  "daily_email": True,
  "sms": False,
  "timezone": None,
  "backup": undefined
}}`,
    schema: toolSchema("set_preferences", {
      daily_email: { type: "boolean" },
      sms: { type: "boolean" },
      timezone: { type: "null" },
      backup: { type: "null" },
    }),
  },
  {
    label: "Comments",
    group: "stream",
    description: "Remove comments and trailing commas without changing payload values.",
    input: `{
  "tool": "fetch_url",
  "args": {
    // Defaults to the public help page
    "url": "https://example.com/help",
    "retries": /* rate-limit budget */ 2,
  },
}`,
    schema: toolSchema("fetch_url", {
      url: { type: "string", minLength: 8 },
      retries: { type: "integer", minimum: 0, maximum: 5 },
    }),
  },
  {
    label: "Keys & commas",
    group: "stream",
    description: "Repair bare keys, single quotes, missing commas, and line breaks.",
    input: `{
  tool: 'send_notice'
  args: {
    channel: 'ops',
    body: 'Checkout is back online
Thanks for your patience',
  },
}`,
    schema: toolSchema("send_notice", {
      channel: { enum: ["ops", "support"] },
      body: { type: "string", maxLength: 160 },
    }),
  },
  {
    label: "Schema rejection",
    group: "precision",
    description: "Inspect rejected payment arguments and the retry prompt.",
    input: `{
  "tool": "record_payment",
  "args": {
    "amount": -12.5,
    "currency": "BTC",
    "tags": ["invoice", 42,],
  }
}`,
    schema: toolSchema("record_payment", {
      amount: { type: "number", minimum: 0 },
      currency: { enum: ["USD", "EUR", "CNY"] },
      tags: { type: "array", items: { type: "string" } },
    }),
  },
];

const labFixtures = [
  {
    label: "Travel booking duel",
    group: "stream",
    description: "Watch fields appear from Wasm GC patches while JSON.parse waits for the last chunk.",
    input: '{"tool":"plan_trip","args":{"title":"Weekend in Osaka","destination":"Osaka","budget":680,"risk":"low","completion":100}}',
    modes: { duel: "travel" },
  },
  {
    label: "Semantic normalization",
    group: "precision",
    description: "Normalize a field name and enum spelling while preserving the exact amount.",
    input: "{tool:'record_payment',args:{userName:'Ada',currency:' usd ',amount:'9007199254740993'}}",
    schema: toolSchema("record_payment", {
      type: "object",
      required: ["user_name", "currency", "amount"],
      properties: {
        user_name: { type: "string" },
        currency: { enum: ["USD", "EUR"] },
        amount: { type: "integer" },
      },
      additionalProperties: false,
    }),
    modes: { coerce: true, semantic: true, diagnostics: true },
  },
  {
    label: "Patch stream",
    group: "stream",
    description: "Watch RFC 6902 operations and field sealing as the call grows.",
    modes: { ignoreThink: true },
    input: [
      "<think>",
      '{"tool":"scratch","args":{"order/id":17}}',
      "</think>",
      '{"tool":"update_order","args":{',
      '  "order/id":9007199254740993,',
      '  "line~item":"Gate ready for noon",',
      '  "memo":"Customer requested a noon pickup',
    ].join("\n"),
    schema: toolSchema("update_order", {
      "order/id": { type: "integer" },
      "line~item": { type: "string" },
      memo: { type: "string" },
    }),
  },
  {
    label: "Precision & coercion",
    group: "precision",
    description: "Preserve integers beyond JavaScript precision and coerce argument types by schema.",
    modes: { json5: true, coerce: true },
    input: [
      '{',
      '  "tool": "record_payment",',
      '  "args": {',
      '    "request_id": 0x20000000000001,',
      '    "amount": "42.5",',
      '    "approved": "true",',
      '    "tags": "invoice",',
      '    "currency": "USD',
    ].join("\n"),
    schema: toolSchema("record_payment", {
      request_id: { type: "integer" },
      amount: { type: "number", minimum: 0 },
      approved: { type: "boolean" },
      tags: { type: "array", items: { type: "string" } },
      currency: { enum: ["USD", "EUR", "CNY"] },
    }),
  },
  {
    label: "Multiple calls",
    group: "stream",
    description: "Locate and repair each JSON tool call in a mixed response.",
    modes: { extract: true },
    input: [
      "First, search the project docs:",
      "```json",
      '{"tool":"search_docs","args":{"query":"MoonBit"}}',
      "```",
      "",
      "Next, get the balance:",
      '{"tool":"get_balance","args":{"account":9007199254740993}}',
      "",
      "Then send a notice:",
      '{"tool":"send_notice","args":{"message":"Ready',
    ].join("\n"),
  },
  {
    label: "Reasoning draft + truncated calls",
    group: "stream",
    description: "Isolate reasoning while retaining literal tags in argument strings.",
    modes: { extract: true, ignoreThink: true },
    input: [
      "<ThInK>",
      "Possible call, still a draft:",
      '{"tool":"draft_guess","args":{"account":7,}}',
      "</tHiNk>",
      '{"tool":"get_balance","args":{',
      '  "account":9007199254740993,',
      '  "note":"Literal <think>marker</think>"',
      '}}',
      "",
      '{"tool":"send_notice","args":{"message":"Status 🌙',
    ].join("\n"),
    schema: {
      type: "object",
      required: ["tool", "args"],
      properties: {
        tool: { enum: ["get_balance", "send_notice"] },
        args: {
          type: "object",
          properties: { account: { type: "integer" }, message: { type: "string" } },
        },
      },
    },
  },
  {
    label: "50 KB write_file",
    group: "latency",
    description: "Replay a 50 KB code argument and compare incremental and full-prefix latency.",
    input: writeFileInput,
    schema: toolSchema("write_file", writeFileSchema),
    transport: 256,
  },
  {
    label: "MCP tools/call",
    group: "mcp",
    description: "Repair and validate a JSON-RPC tool call while preserving its exact ID.",
    input: truncatedMcpCall("{path:'notes.md', content:'hello from MoonBit'"),
    schema: mcpRegistry,
    modes: { mcp: true },
  },
  {
    label: "MCP invalid params",
    group: "mcp",
    description: "Inspect a structured -32602 response and its retry guidance.",
    input: truncatedMcpCall("{path:'', content:17"),
    schema: mcpRegistry,
    modes: { mcp: true, coerce: true },
  },
];
