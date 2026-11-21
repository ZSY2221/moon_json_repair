# MoonBit agent gateway

Run this independent consumer in the example directory once version 0.5.0 is available on Mooncakes.

~~~sh
moon run --target wasm-gc --deny-warn .
~~~

From the repository root, verify against the exact source in the checkout without contacting Mooncakes.

~~~sh
node tools/verify-examples.mjs wasm-gc
~~~

The example removes a reasoning block, repairs an unfinished object, recovers user_name and USD, and converts a decimal order ID without rounding.

The amount fails the schema minimum. The diagnostic points to its span in the recovered JSON, and the retry prompt limits the correction to that field. A gateway can forward the recovered arguments after the remaining validation issue is resolved.
