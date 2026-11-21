/** A number lexeme preserved without conversion through IEEE 754. */
export class ExactJsonNumber {
  constructor(source: string);
  readonly source: string;
  toString(): string;
}

export type JsonValue =
  | null | boolean | string | number | ExactJsonNumber
  | JsonValue[] | { [key: string]: JsonValue };

export interface SourcePosition {
  /** Zero-based UTF-16 code-unit offset. */
  offset: number;
  /** One-based source line. */
  line: number;
  /** One-based UTF-16 column. */
  column: number;
}

export interface StreamStatus {
  position: SourcePosition;
  depth: number;
  stack: ("}" | "]")[];
  quote?: "'" | '"';
  in_comment: boolean;
  stable: boolean;
  stable_offset: number;
  finalized: boolean;
}

export interface RepairEdit {
  kind: string;
  action: string;
  position: SourcePosition;
  end_offset: number;
  replacement: string;
}

export interface RepairError {
  kind: "empty_input" | "unexpected_token" | "invalid_unicode" | "invalid_number"
    | "duplicate_key" | "trailing_content" | "depth_limit" | "input_limit" | "edit_limit";
  message: string;
  position: SourcePosition;
}

export interface RepairReport {
  /** Canonical repaired JSON text with the original number lexemes intact. */
  json: string;
  value: JsonValue;
  edits: RepairEdit[];
}

export interface ValidationError {
  path: string;
  keyword: string;
  message: string;
}

export interface CoercionEdit {
  path: string;
  kind: string;
  before: JsonValue;
  after: JsonValue;
}

export type Validation =
  | { state: "skipped" }
  | { state: "invalid_json"; message: string }
  | { state: "checked"; errors: ValidationError[] };

export type JsonPatch =
  | { op: "add" | "replace"; path: string; value: JsonValue }
  | { op: "remove"; path: string };

export interface FieldSeal {
  pointer: string;
  sealed: boolean;
}

export interface PatchTrace {
  patches: JsonPatch[];
  /** RFC 6902 patch operations as lossless JSON text. */
  patches_json: string;
  fields: FieldSeal[];
  /** Uncoerced value to which the operations apply. */
  json: string;
}

export interface Block {
  start: SourcePosition;
  end: SourcePosition;
  confidence: number;
  report: RepairReport;
  /** JSON text after optional schema coercion. */
  output: string;
  value: JsonValue;
  coercions: CoercionEdit[];
  validation: Validation;
  retry_prompt: string;
  diagnostic?: string;
}

type Positioned = {
  stream: StreamStatus;
  /** Original JSON envelope, safe to forward without numeric rounding. */
  wire: string;
};

export type RepairFailure = Positioned & {
  ok: false;
  error: RepairError;
  diagnostic?: string;
};

export type RepairSuccess<Blocks extends Block[]> = Positioned & {
  ok: true;
  blocks: Blocks;
};

export type RepairResult = RepairSuccess<[Block]> | RepairFailure;
export type ExtractionResult = RepairSuccess<Block[]> | RepairFailure;
export type PatchResult = RepairSuccess<[Block & { trace: PatchTrace }]> | RepairFailure;
export type PushResult = (Positioned & { ok: true }) | RepairFailure;

export interface SyntaxOptions {
  json5?: boolean;
  ignoreThink?: boolean;
  coerce?: boolean;
}

export interface RepairOptions extends SyntaxOptions {
  /** JSON Schema text. Keeping the argument as JSON text retains exact limits. */
  schema?: string;
  /** Enable opt-in semantic coercions in addition to the basic coercions. */
  semantic?: boolean;
  /** Include localized compiler-style audit and validation text when applicable. */
  diagnostics?: boolean;
  language?: "en" | "zh";
}

export interface RepairStream {
  /** Append one chunk atomically. The successful prefix survives a rejection. */
  push(chunk: string): PushResult;
  preview(): RepairResult;
  /** Returns the next patch frame. Successful frames advance this stream's baseline. */
  nextPatches(): PatchResult;
  /** Finalize and release Wasm state. Repeated finalization returns the same result. */
  finalize(): RepairResult;
  /** Release this stream when ending it before finalization. Idempotent. */
  close(): void;
}

export interface McpGuardDecision {
  forward: boolean;
  frame?: string;
  tool?: string;
  audit: {
    envelope_edits: number;
    argument_edits: number;
    coercions: number;
  };
  error_code?: number;
  wire: string;
}

export type McpGuardResult = McpGuardDecision | { registry_error: string; wire: string };

export interface RepairEngine {
  readonly backend: "wasm-gc";
  repair(source: string, options?: RepairOptions): RepairResult;
  extractAll(source: string, options?: RepairOptions): ExtractionResult;
  createStream(options?: RepairOptions): RepairStream;
  /** Registry maps tool names to parameter schemas and is supplied as lossless JSON text. */
  guardMcpToolCall(source: string, registry: string, options?: SyntaxOptions): McpGuardResult;
}

export interface EngineOptions {
  /** Defaults to engine.wasm adjacent to the ESM module. Precompiled modules need JS string builtins. */
  wasm?: URL | BufferSource | WebAssembly.Module;
}

export function createRepairEngine(options?: EngineOptions): Promise<RepairEngine>;
