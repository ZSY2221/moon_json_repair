# Browser Wasm GC

Open [index.html](index.html) directly from the checkout in a browser with Wasm GC and JS string builtins. No server or frontend build step is needed. The relative script path loads the checked-in Wasm bytes, then the page calls the engine's stream exports for each chunk.

The example times each push and read. Keep the returned wire JSON as text when sending or storing it. Parsing that text into JavaScript numbers would round wide integer IDs.

From the repository root, run the same code with Node 24 and assert every snapshot.

~~~sh
node tools/verify-examples.mjs --browser
~~~
