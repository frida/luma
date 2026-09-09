export interface EncodeOptions {
    maxDepth?: number;
}

const DEFAULT_MAX_DEPTH = 3;

export type PackedValue = [EncodedValueTree, ArrayBuffer | null];
export type PackedValues = [EncodedValueTree[], ArrayBuffer | null];

export type EncodedValueTree = EncodedValue;

type EncodedValue = [ValueTag, ...any[]];

type BytesEncoded = [tag: ValueTag.Bytes, offset: number, length: number, kind: BytesKind];
type BytesKind = "ArrayBuffer" | "DataView" | TypedArrayName;

const enum ValueTag {
    Number = 0,
    String = 1,
    Object = 2,
    Array = 3,
    NativePointer = 4,
    Null = 5,
    Boolean = 6,
    Bytes = 7,
    Function = 8,
    Error = 9,
    Undefined = 10,
    BigInt = 11,
    Symbol = 12,
    Date = 13,
    RegExp = 14,
    Map = 15,
    Set = 16,
    Promise = 17,
    WeakMap = 18,
    WeakSet = 19,
    DepthLimit = 20,
    Circular = 21,
}

type TypedArrayName =
    | "Int8Array"
    | "Uint8Array"
    | "Uint8ClampedArray"
    | "Int16Array"
    | "Uint16Array"
    | "Int32Array"
    | "Uint32Array"
    | "Float32Array"
    | "Float64Array"
    | "BigInt64Array"
    | "BigUint64Array";

interface EncodeState {
    seen: Map<unknown, number>;
    nextId: number;
}

export function encodeValue(value: unknown, options?: EncodeOptions): PackedValue {
    const chunks: BinaryChunk[] = [];
    const maxDepth = options?.maxDepth ?? DEFAULT_MAX_DEPTH;
    const tree = collectTree(value, chunks, maxDepth, makeEncodeState());
    const blob = packChunks(chunks);
    return [tree, blob];
}

export function encodeValues(values: unknown[], options?: EncodeOptions): PackedValues {
    const chunks: BinaryChunk[] = [];
    const maxDepth = options?.maxDepth ?? DEFAULT_MAX_DEPTH;
    const trees: EncodedValueTree[] = [];
    for (const value of values) {
        trees.push(collectTree(value, chunks, maxDepth, makeEncodeState()));
    }
    const blob = packChunks(chunks);
    return [trees, blob];
}

function makeEncodeState(): EncodeState {
    return {
        seen: new Map(),
        nextId: 1
    };
}

function collectTree(
    root: unknown,
    chunks: BinaryChunk[],
    maxDepth: number,
    state: EncodeState
): EncodedValueTree {
    const slot: EncodedValueTree[] = [];
    const pending: PendingValue[] = [{ value: root, depth: 0, target: slot, index: 0 }];

    while (pending.length !== 0) {
        const { value, depth, target, index } = pending.pop()!;
        target[index] = encodeValueTree(value, chunks, maxDepth, depth, state, pending);
    }

    return slot[0];
}

function encodeValueTree(
    value: unknown,
    chunks: BinaryChunk[],
    maxDepth: number,
    depth: number,
    state: EncodeState,
    pending: PendingValue[]
): EncodedValueTree {
    if (value === null) {
        return [ValueTag.Null];
    }

    const t = typeof value;

    if (t === "number") {
        return [ValueTag.Number, value as number];
    }

    if (t === "string") {
        return [ValueTag.String, value as string];
    }

    if (t === "object") {
        return encodeObjectTree(value as any, chunks, maxDepth, depth, state, pending);
    }

    if (t === "boolean") {
        return [ValueTag.Boolean, value as boolean];
    }

    if (t === "function") {
        const fn = value as Function;
        const name = fn.name ?? "";
        const sig = name === "" ? "[Function]" : `[Function: ${name}]`;
        return [ValueTag.Function, sig];
    }

    if (t === "undefined") {
        return [ValueTag.Undefined];
    }

    if (t === "bigint") {
        const big = value as bigint;
        return [ValueTag.BigInt, big.toString()];
    }

    if (t === "symbol") {
        return [ValueTag.Symbol, String(value)];
    }

    return [ValueTag.Undefined];
}

function encodeObjectTree(
    value: any,
    chunks: BinaryChunk[],
    maxDepth: number,
    depth: number,
    state: EncodeState,
    pending: PendingValue[]
): EncodedValueTree {
    let obj = value;

    while (true) {
        if (obj instanceof NativePointer) {
            return [ValueTag.NativePointer, (obj as NativePointer).toString()];
        }

        if (isBinaryLike(obj)) {
            const binary = obj as ArrayBufferView | ArrayBuffer;
            const node: BytesEncoded = [ValueTag.Bytes, 0, 0, getBytesKind(binary)];
            chunks.push({ buf: binary, node });
            return node;
        }

        if (obj instanceof Error) {
            const err = obj as Error;
            const name = err.name ?? "Error";
            const message = err.message ?? "";
            const stack = err.stack ?? "";
            return [ValueTag.Error, name, message, stack];
        }

        if (obj instanceof Date) {
            return [ValueTag.Date, (obj as Date).toISOString()];
        }

        if (obj instanceof RegExp) {
            const r = obj as RegExp;
            return [ValueTag.RegExp, r.source, r.flags];
        }

        if (obj instanceof Promise) {
            return [ValueTag.Promise];
        }

        if (obj instanceof WeakMap) {
            return [ValueTag.WeakMap];
        }

        if (obj instanceof WeakSet) {
            return [ValueTag.WeakSet];
        }

        const isArray = Array.isArray(obj);
        const isMap = obj instanceof Map;
        const isSet = obj instanceof Set;

        const existingId = state.seen.get(obj);
        if (existingId !== undefined) {
            return [ValueTag.Circular, existingId];
        }

        if (depth >= maxDepth) {
            if (isArray) {
                return [ValueTag.DepthLimit, ValueTag.Array];
            }
            if (isMap) {
                return [ValueTag.DepthLimit, ValueTag.Map];
            }
            if (isSet) {
                return [ValueTag.DepthLimit, ValueTag.Set];
            }
            return [ValueTag.DepthLimit, ValueTag.Object];
        }

        const id = state.nextId++;
        state.seen.set(obj, id);

        if (!isArray && !isMap && !isSet) {
            const converted = convertedThroughToJson(obj);
            if (converted !== obj) {
                obj = converted;
                continue;
            }
        }

        const wanted: PendingValue[] = [];

        if (isMap) {
            const entries: EncodedEntry[] = [];
            for (const [k, v] of (obj as Map<unknown, unknown>).entries()) {
                const entry: EncodedEntry = [] as unknown as EncodedEntry;
                entries.push(entry);
                wanted.push({ value: k, depth: depth + 1, target: entry, index: 0 });
                wanted.push({ value: v, depth: depth + 1, target: entry, index: 1 });
            }
            expectAll(pending, wanted);
            return [ValueTag.Map, id, entries];
        }

        if (isSet) {
            const items: EncodedValueTree[] = [];
            let index = 0;
            for (const v of (obj as Set<unknown>).values()) {
                wanted.push({ value: v, depth: depth + 1, target: items, index: index++ });
            }
            expectAll(pending, wanted);
            return [ValueTag.Set, id, items];
        }

        if (isArray) {
            const elements: EncodedValueTree[] = [];
            const values = obj as unknown[];
            for (let index = 0; index !== values.length; index++) {
                wanted.push({ value: values[index], depth: depth + 1, target: elements, index });
            }
            expectAll(pending, wanted);
            return [ValueTag.Array, id, elements];
        }

        const entries: EncodedEntry[] = [];

        for (const k of Object.keys(obj as Record<string, unknown>)) {
            const entry: EncodedEntry = [[ValueTag.String, k], []] as unknown as EncodedEntry;
            entries.push(entry);
            wanted.push({ value: obj[k], depth: depth + 1, target: entry, index: 1 });
        }

        for (const s of Object.getOwnPropertySymbols(obj as object)) {
            if (!Object.prototype.propertyIsEnumerable.call(obj, s)) {
                continue;
            }
            const entry: EncodedEntry = [[ValueTag.Symbol, String(s)], []] as unknown as EncodedEntry;
            entries.push(entry);
            wanted.push({ value: obj[s], depth: depth + 1, target: entry, index: 1 });
        }

        expectAll(pending, wanted);
        return [ValueTag.Object, id, entries];
    }
}

// The pending list is walked from the back, so what a value holds is put there
// in reverse -- that way each one is encoded in the order it was found in.
function expectAll(pending: PendingValue[], wanted: PendingValue[]): void {
    for (let i = wanted.length - 1; i !== -1; i--) {
        pending.push(wanted[i]);
    }
}

function convertedThroughToJson(obj: any): unknown {
    try {
        const maybeToJSON = obj.toJSON;
        if (typeof maybeToJSON === "function") {
            return maybeToJSON.call(obj);
        }
    } catch {
    }

    return obj;
}

interface BinaryChunk {
    buf: ArrayBufferView | ArrayBuffer;
    node: BytesEncoded;
}

interface PendingValue {
    value: unknown;
    depth: number;
    target: EncodedValueTree[];
    index: number;
}

type EncodedEntry = [EncodedValueTree, EncodedValueTree];

function packChunks(chunks: BinaryChunk[]): ArrayBuffer | null {
    if (chunks.length === 0) {
        return null;
    }

    let total = 0;
    for (const { buf } of chunks) {
        total += buf.byteLength;
    }

    const blob = new Uint8Array(total);

    let offset = 0;
    for (const { buf, node } of chunks) {
        const raw = buf instanceof ArrayBuffer
            ? new Uint8Array(buf)
            : new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
        blob.set(raw, offset);

        node[1] = offset;
        node[2] = raw.byteLength;

        offset += raw.byteLength;
    }

    return blob.buffer;
}

function getBytesKind(v: ArrayBufferView | ArrayBuffer): BytesKind {
    if (v instanceof ArrayBuffer) {
        return "ArrayBuffer";
    }
    if (v instanceof DataView) {
        return "DataView";
    }
    const ctor = (v as { constructor?: { name?: string } }).constructor;
    const name = ctor?.name ?? "ArrayBuffer";
    return name as BytesKind;
}

function isBinaryLike(v: unknown): v is ArrayBufferView | ArrayBuffer {
    return v instanceof ArrayBuffer || ArrayBuffer.isView(v);
}
