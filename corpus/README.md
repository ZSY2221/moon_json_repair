# Conformance and model-output fixtures

`rfc8259.json` contains 248 cases. The upstream subset is pinned to JSONTestSuite revision `1ef36fa01286573e846ac449e8683f8833c5b26a`. The original fixture basenames identify upstream inputs. Keep `LICENSE-JSONTestSuite` with redistributed fixtures. Project additions are labeled with their RFC section. [Pinned JSONTestSuite](https://github.com/nst/JSONTestSuite/tree/1ef36fa01286573e846ac449e8683f8833c5b26a/test_parsing)

- `y` has 93 upstream inputs. The expected text removes insignificant whitespace and preserves string escapes and decimal lexemes. All must need zero edits.
- `n` has 130 cases selected for explicit repair or rejection under the repair contract, including project additions for raw code points U+0000 through U+001F.
- `i` has 25 interoperability and policy cases, including extreme decimal lexemes, a leading BOM, surrogate escapes, the nesting limit, and two upstream `y_object_duplicated*` fixtures. Section 4 permits parsing duplicate names and recommends uniqueness. The tool-call parser deliberately rejects duplicates.

Examples with non-UTF-8 bytes belong at a byte decoder boundary. The conformance runner passes Unicode strings to the repair API and tests malformed JSON escape spellings separately. Every successful fixture is checked with the strict core parser and a second repair pass.

`cases.mjs` holds synthetic examples modeled on tool-call failure patterns. They contain no provider transcripts or customer data. `tools/eval-corpus.mjs` keeps expected output, actual serialization, schema paths, and protective failures distinct.

Regenerate MoonBit tests after editing the manifest.

```sh
node tools/rfc-fixtures.mjs
moon fmt
moon test --deny-warn
```

[RFC 8259](https://www.rfc-editor.org/rfc/rfc8259)
