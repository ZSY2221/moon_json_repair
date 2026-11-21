# Stream exact JSON patches in TypeScript

From the repository root in Node 22.19+ or Node 24:

```sh
node packages/json-repair-wasm/build.mjs
node examples/02-ts-wasm-gc-sdk/main.mts
```

The MoonBit build produces a Wasm GC module. The consumer uses Node's built-in
TypeScript stripping and makes no runtime package requests. The example feeds
three model chunks into an isolated stream, emits each patch array as JSON, and
verifies that the final tool-call ID stays `9007199254740993` in both the
decoded value and the wire payload.

Use `trace.patches_json` to forward an RFC 6902 frame as JSON.
`trace.fields` reports which JSON Pointers were physically closed in the
stream. The initial patch frame applies to JSON `null`. Call `finalize()`
at transport EOF or `close()` if you cancel the request.

For a backend with multiple active requests, create a separate stream per
request. Patch baselines and accepted input are isolated. See the
[SDK API](../../packages/json-repair-wasm/README.md).
