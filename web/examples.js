"use strict";

const toolSchema = (tool, properties) => ({
  type: "object",
  required: ["tool", "args"],
  properties: {
    tool: { type: "string", enum: [tool] },
    args: { type: "object", required: Object.keys(properties), properties },
  },
});

const examples = [
  {
    label: "Stream cut",
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
    label: "Precision & coercion",
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
    label: "推理草稿 + 截断调用",
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
];
