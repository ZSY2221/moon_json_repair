"use strict";

// A display index for strict JSON already verified by MoonBit. Only object key
// strings are decoded. Numeric lexemes are never parsed into JS numbers.
function jsonView(text) {
  const tokens = Array.from(text.matchAll(/"(?:\\[\s\S]|[^"\\])*"|true|false|null|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[{}\[\],:]/g),
    ({ 0: token, index }) => ({ text: token, start: index, end: index + token.length }));
  const values = new Map();
  const identities = new Map();
  let index = 0;
  function take(path, role, style = "") {
    const token = tokens[index++];
    token.path = path;
    token.style = style;
    token.identity = JSON.stringify([path, role]);
    identities.set(token.identity, token);
    return token;
  }
  function visit(path, parent) {
    const start = tokens[index].start;
    const symbol = tokens[index].text;
    if (symbol === "{") {
      take(path, "open");
      while (tokens[index].text !== "}") {
        const name = JSON.parse(tokens[index].text);
        const key = path + (/^[A-Za-z_][A-Za-z_0-9]*$/.test(name) ? "." + name : "[" + JSON.stringify(name) + "]");
        take(key, "key", "key");
        take(key, "colon");
        visit(key, path);
        if (tokens[index].text === ",") take(key, "comma");
      }
      take(path, "close");
    } else if (symbol === "[") {
      take(path, "open");
      let item = 0;
      while (tokens[index].text !== "]") {
        const key = path + "[" + item++ + "]";
        visit(key, path);
        if (tokens[index].text === ",") take(key, "comma");
      }
      take(path, "close");
    } else {
      take(path, "value", symbol.startsWith('"') ? "string" : /^[tfn]/.test(symbol) ? "literal" : "number");
    }
    values.set(path, { start, end: tokens[index - 1].end, parent });
  }
  if (tokens.length > 0) visit("$", null);
  return { text, tokens, values, identities };
}

function highlightText(text, offset, selection, caret) {
  if (!selection) return document.createTextNode(text);
  const { start, end } = selection;
  const limit = offset + text.length;
  if (start === end && caret && start >= offset && start < limit) {
    const point = start - offset;
    const fragment = document.createDocumentFragment();
    const marker = document.createElement("span");
    marker.className = "diff-anchor";
    fragment.append(text.slice(0, point), marker, text.slice(point));
    return fragment;
  }
  const low = Math.max(start, offset);
  const high = Math.min(end, limit);
  if (low >= high) return document.createTextNode(text);
  const fragment = document.createDocumentFragment();
  const marker = document.createElement("mark");
  marker.className = "diff";
  marker.textContent = text.slice(low - offset, high - offset);
  fragment.append(text.slice(0, low - offset), marker, text.slice(high - offset));
  return fragment;
}

function endAnchor(container) {
  const marker = document.createElement("span");
  marker.className = "diff-anchor";
  container.append(marker);
}

function prettyView(model, selection) {
  const fragment = document.createDocumentFragment();
  let depth = 0;
  const line = () => fragment.append("\n" + "  ".repeat(depth));
  for (const [index, token] of model.tokens.entries()) {
    const previous = model.tokens[index - 1]?.text;
    const next = model.tokens[index + 1]?.text;
    if (token.text === "}" || token.text === "]") {
      depth--;
      if (previous !== "{" && previous !== "[") line();
    }
    const span = document.createElement("span");
    span.className = token.style ? "token-" + token.style : "";
    span.dataset.start = token.start;
    span.dataset.end = token.end;
    span.append(highlightText(token.text, token.start, selection, true));
    fragment.append(span);
    if (token.text === "{" || token.text === "[") {
      depth++;
      if (next !== "}" && next !== "]") line();
    } else if (token.text === ",") {
      line();
    } else if (token.text === ":") {
      fragment.append(" ");
    }
  }
  if (selection?.start === model.text.length && selection.end === selection.start) endAnchor(fragment);
  return fragment;
}

// Use the audit as a source map, checking each consumed code unit against the
// emitted JSON. This only correlates positions. MoonBit owns the repaired text.
function traceProjection(source, model, edits, start, end) {
  const ranges = new Array(edits.length);
  const from = new Int32Array(model.text.length + 1);
  const to = new Int32Array(model.text.length + 1);
  const ordered = edits.map((edit, index) => ({ edit, index }))
    .sort((a, b) => a.edit.position.offset - b.edit.position.offset || a.index - b.index);
  let offset = 0;
  let cursor = start;
  let quoted = false;
  let escaped = false;
  let matches = true;
  function mapText(text, first, last, replacement) {
    for (let index = 0; index < text.length; index++) {
      const unit = text[index];
      if (!quoted && !replacement && (unit === " " || unit === "\t" || unit === "\r" || unit === "\n")) continue;
      if (model.text[offset] !== unit) {
        matches = false;
        return;
      }
      from[offset] = replacement ? first : first + index;
      to[offset++] = replacement ? last : first + index + 1;
      if (escaped) escaped = false;
      else if (quoted && unit === "\\") escaped = true;
      else if (unit === '"') quoted = !quoted;
    }
  }
  for (const { edit, index } of ordered) {
    const first = edit.position.offset;
    const last = edit.end_offset;
    // Extraction can attach an ignored reasoning range outside this candidate.
    // It has a source location and no counterpart in this block's JSON.
    if (edit.kind === "ignore_think_block" && (last <= start || first >= end)) continue;
    if (first < cursor || last < first || last > end) return null;
    mapText(source.slice(cursor, first), cursor, first, false);
    if (!matches) return null;
    const begin = offset;
    mapText(edit.replacement, first, last, true);
    if (!matches) return null;
    ranges[index] = { start: begin, end: offset };
    cursor = last;
  }
  mapText(source.slice(cursor, end), cursor, end, false);
  if (!matches || offset !== model.text.length) return null;
  from[offset] = end;
  to[offset] = end;
  return { ranges, from, to };
}

function remapOutput(range, before, after) {
  if (before === after) return range;
  let low = 0;
  let high = before.tokens.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    if (before.tokens[middle].end <= range.start) low = middle + 1;
    else high = middle;
  }
  const found = before.tokens[low];
  const token = found && found.start <= range.start ? found : before.tokens.at(-1);
  const corresponding = token && after.identities.get(token.identity);
  if (corresponding && corresponding.text === token.text && range.end <= token.end) {
    return {
      start: corresponding.start + Math.min(token.text.length, range.start - token.start),
      end: corresponding.start + Math.min(token.text.length, range.end - token.start),
    };
  }
  return after.values.get(token?.path) ?? { start: after.text.length, end: after.text.length };
}

function makeVisualAudit(source, block) {
  const before = jsonView(block.report.json);
  const after = block.output === before.text ? before : jsonView(block.output);
  const first = block.start.offset;
  const last = block.end.offset;
  const mapping = traceProjection(source, before, block.report.edits, first, last);
  const edits = block.report.edits.map((edit, index) => ({
    label: edit.action,
    kind: edit.kind,
    location: "L" + edit.position.line + ":C" + edit.position.column,
    source: { start: edit.position.offset, end: edit.end_offset },
    output: mapping?.ranges[index] ? remapOutput(mapping.ranges[index], before, after) : null,
  }));
  for (const change of block.coercions) {
    const output = after.values.get(change.path);
    let path = change.path;
    while (path && !before.values.has(path)) path = after.values.get(path)?.parent;
    const prior = before.values.get(path);
    const span = prior && mapping && {
      start: mapping.from[prior.start],
      end: mapping.to[prior.end - 1],
    };
    edits.push({
      label: change.path,
      kind: "schema_coerce · " + change.kind,
      location: "Schema",
      source: span || null,
      output: output || null,
    });
  }
  return { output: after, edits };
}
