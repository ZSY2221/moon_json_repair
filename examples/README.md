# Integration examples

| Example | Entry point |
| --- | --- |
| Agent gateway | [Independent MoonBit consumer](01-moonbit-agent-gateway/) |
| TypeScript SDK | [Wasm GC stream and lossless patches](02-ts-wasm-gc-sdk/) |
| Browser Wasm GC | [Offline HTML and JavaScript](02-browser-wasm-gc/) |
| MCP guard | [Native JSON-RPC line pipeline](03-mcp-guard-pipeline/) |

The repository verifies these examples against its current source and browser build. Each example includes its own run command.

~~~sh
node tools/verify-examples.mjs
node packages/json-repair-wasm/build.mjs
node --test packages/json-repair-wasm/index.test.mjs
node examples/02-ts-wasm-gc-sdk/main.mts
~~~
