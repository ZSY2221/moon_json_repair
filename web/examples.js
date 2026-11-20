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
