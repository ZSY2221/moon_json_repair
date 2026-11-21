# MCP tool-call guard

Run from the repository root with a Native MoonBit toolchain and a local C compiler.

~~~sh
moon run --target native cmd/main -- --mcp-guard --tool-schemas examples/03-mcp-guard-pipeline/tools.json --coerce examples/03-mcp-guard-pipeline/requests.ndjson
~~~

| Input | Expected action |
| --- | --- |
| Tools listing | Forward the unchanged frame |
| Valid read request | Forward the unrounded integer ID |
| Truncated create request | Repair the envelope and stringified arguments, then coerce exact numeric strings |
| Negative amount | Return JSON-RPC error -32602 with the amount path and a retry prompt |

Pass a single hyphen as the input path to receive one frame per line from stdin. An adapter sends forwardable requests downstream and generated errors back upstream. The example only handles protocol frames and performs no tool actions.

The regression script sends these fixtures to the compiled Native CLI through stdin and checks strict exit code 3. The same frames are also checked against the browser Wasm GC engine.

~~~sh
node tools/verify-examples.mjs native
node tools/verify-examples.mjs --browser
~~~
