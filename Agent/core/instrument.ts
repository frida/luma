import { encodeValue } from "./value.js";

export interface Instrument<C = unknown, R = unknown> {
    create(
        ctx: InstrumentContext,
        initialConfig: C,
        restored: R
    ): InstrumentHandle<C> | Promise<InstrumentHandle<C>>;
}

export interface InstrumentContext {
    instanceId: string;
    emit(payload: unknown): void;
    post(type: string, payload: object, data?: ArrayBuffer | ArrayBufferView | number[] | null): void;
    widget(id: string): WidgetHandle;
}

export interface WidgetHandle {
    setCounter(value: CounterValue): void;
    setHistogram(buckets: HistogramBucket[]): void;
    incrementBucket(label: string, by?: number): void;
    push(point: GraphPoint): void;
    upsertItem(item: ListItem): void;
    removeItem(id: string): void;
    upsertRow(row: TableRow): void;
    removeRow(id: string): void;
    setHex(state: HexValue): void;
    appendConsole(entry: ConsoleEntry): void;
    appendOutput(text: string): void;
    appendError(text: string): void;
    appendValue(value: unknown): void;
    appendImage(image: ConsoleImage): void;
    setState(value: unknown, data?: ViewData | null): void;
    sendEvent(value: unknown, data?: ViewData | null): void;
    setActionEnabled(action: string, enabled: boolean): void;
    clear(): void;
}

export type ViewData = ArrayBuffer | ArrayBufferView | number[];

export interface CounterValue {
    value: number;
    unit?: string;
    delta?: number;
}

export interface HistogramBucket {
    label: string;
    count: number;
}

export interface GraphPoint {
    series: string;
    x: number;
    y: number;
}

export interface ListItem {
    id: string;
    title: string;
    subtitle?: string;
    accessory?: string;
}

export interface TableRow {
    id: string;
    cells: { [columnId: string]: string };
}

export interface HexValue {
    bytes: ArrayBuffer | number[];
    baseAddress?: number | string;
}

export interface ConsoleEntry {
    id?: string;
    kind: "input" | "output" | "error";
    text: string;
}

export interface ConsoleImage {
    bytes: ArrayBuffer | Uint8Array | number[];
    mediaType: string;
    width: number;
    height: number;
    text?: string;
}

export interface WidgetAction {
    widget: string;
    action: string;
    item?: string;
}

export interface ConsoleInput {
    widget: string;
    entryId: string;
    text: string;
}

export interface ViewMessage {
    widget: string;
    value: unknown;
    data: ArrayBuffer | null;
    from?: { id: string; name: string };
}

export interface ConsoleResponder {
    output(text: string): void;
    error(text: string): void;
    value(v: unknown): void;
    image(img: ConsoleImage): void;
}

export interface InstrumentHandle<C = unknown> {
    updateConfig?(config: C): Promise<void> | void;
    onAction?(action: WidgetAction): Promise<void> | void;
    onConsoleInput?(input: ConsoleInput, respond: ConsoleResponder): Promise<void> | void;
    onViewMessage?(message: ViewMessage): Promise<void> | void;
    dispose?(): Promise<void> | void;
}

interface InstrumentController {
    instrument: Instrument;
    config: unknown;
    handle: InstrumentHandle;
}

interface InstrumentModule {
    instrument: Instrument;
}

const instruments = new Map<string, InstrumentController>();
const modules = new Map<string, Instrument>();

const viewLimits = {
    valueBytes: 256 * 1024,
    stateDataBytes: 64 * 1024 * 1024,
    eventDataBytes: 1024 * 1024,
    stateDataPieceBytes: 4 * 1024 * 1024 - 64 * 1024,
};

declare global {
    function send(message: any, data?: ArrayBuffer | ArrayBufferView | number[] | null): void;
}

interface ViewMessageEnvelope {
    instance_id: string;
    widget: string;
    value: unknown;
    from?: { id: string; name: string };
}

function receiveViewMessages(): void {
    recv("luma:view-message", (message: ViewMessageEnvelope, data: ArrayBuffer | null) => {
        receiveViewMessages();
        const handle = instruments.get(message.instance_id)?.handle;
        if (handle?.onViewMessage === undefined) {
            return;
        }
        const delivered: ViewMessage = { widget: message.widget, value: message.value, data };
        if (message.from !== undefined) {
            delivered.from = message.from;
        }
        handle.onViewMessage(delivered);
    });
}

receiveViewMessages();

export async function loadInstrument({ instanceId, moduleName, source, config, restored }: {
    instanceId: string,
    moduleName: string,
    source: string,
    config: unknown,
    restored: unknown,
}): Promise<void> {
    const instrument = await loadInstrumentModule(moduleName, source);
    const ctx = makeInstrumentContext(instanceId);

    ctx.post("instrument-actions-reset", {});
    const handle = await instrument.create(ctx, config, restored);

    const controller: InstrumentController = {
        instrument,
        config,
        handle,
    };

    instruments.set(instanceId, controller);
}

export async function updateInstrumentConfig({ instanceId, config }: {
    instanceId: string,
    config: unknown,
}): Promise<void> {
    const controller = instruments.get(instanceId);
    if (controller === undefined) {
        throw new Error(`No such instance: ${instanceId}`);
    }

    controller.config = config;

    await controller.handle.updateConfig?.(config);
}

export async function disposeInstrument({ instanceId }: { instanceId: string }): Promise<void> {
    const controller = instruments.get(instanceId);
    if (controller === undefined) {
        throw new Error(`No such instance: ${instanceId}`);
    }

    await controller.handle.dispose?.();

    instruments.delete(instanceId);
}

export async function invokeWidgetAction({ instanceId, widget, action, item }: {
    instanceId: string,
    widget: string,
    action: string,
    item?: string,
}): Promise<void> {
    const controller = instruments.get(instanceId);
    if (controller === undefined) {
        throw new Error(`No such instance: ${instanceId}`);
    }

    const chosen: WidgetAction = { widget, action };
    if (item !== undefined) {
        chosen.item = item;
    }
    await controller.handle.onAction?.(chosen);
}

export async function submitConsoleInput({ instanceId, widget, entryId, text }: {
    instanceId: string,
    widget: string,
    entryId: string,
    text: string,
}): Promise<void> {
    const controller = instruments.get(instanceId);
    if (controller === undefined) {
        throw new Error(`No such instance: ${instanceId}`);
    }

    const respond = makeConsoleResponder(instanceId, widget, entryId);
    try {
        await controller.handle.onConsoleInput?.({ widget, entryId, text }, respond);
    } catch (e) {
        respond.error((e instanceof Error) ? e.message : String(e));
    }
    send({
        type: "widget-console-reply-done",
        instance_id: instanceId,
        widget,
        reply_to: entryId,
    }, null);
}

function makeConsoleResponder(
    instanceId: string,
    widget: string,
    replyTo: string
): ConsoleResponder {
    const postEntry = (
        entry: {
            kind: "output" | "error" | "image";
            text: string;
            value?: unknown;
            image?: { media_type: string; width: number; height: number };
        },
        data: ArrayBuffer | null
    ) => {
        send({
            type: "widget-console-append",
            instance_id: instanceId,
            widget,
            entry: {
                id: makeId(),
                kind: entry.kind,
                text: entry.text,
                value: entry.value,
                image: entry.image,
                reply_to: replyTo,
            },
        }, data);
    };
    return {
        output(text) {
            postEntry({ kind: "output", text }, null);
        },
        error(text) {
            postEntry({ kind: "error", text }, null);
        },
        value(v) {
            const [tree, blob] = encodeValue(v);
            postEntry({ kind: "output", text: "", value: tree }, blob);
        },
        image(img) {
            postEntry(
                {
                    kind: "image",
                    text: img.text ?? "",
                    image: { media_type: img.mediaType, width: img.width, height: img.height },
                },
                consoleImageBuffer(img.bytes)
            );
        },
    };
}

async function loadInstrumentModule(
    moduleName: string,
    source: string
): Promise<Instrument> {
    const cached = modules.get(moduleName);
    if (cached !== undefined) {
        return cached;
    }

    const ns = await Script.load(moduleName, source);
    const instrument = parseInstrumentModule(ns, moduleName);

    modules.set(moduleName, instrument);

    return instrument;
}

function parseInstrumentModule(ns: unknown, name: string): Instrument {
    const { instrument } = ns as { instrument?: Instrument };
    if (typeof instrument?.create !== "function") {
        throw new Error(`Instrument module ${name} does not export a valid instrument`);
    }
    return instrument;
}

function makeInstrumentContext(instanceId: string): InstrumentContext {
    const post = (type: string, payload: object, data?: ArrayBuffer | ArrayBufferView | number[] | null) => {
        send({
            type,
            instance_id: instanceId,
            ...payload,
        }, data ?? null);
    };
    return {
        instanceId,
        emit(payload: unknown) {
            const [tree, blob] = encodeValue(payload);
            send({
                type: "instrument-event",
                instance_id: instanceId,
                payload: tree,
            }, blob);
        },
        post,
        widget(id: string): WidgetHandle {
            return {
                setCounter(value) {
                    post("widget-counter-set", { widget: id, counter: value });
                },
                setHistogram(buckets) {
                    post("widget-histogram-set", { widget: id, buckets });
                },
                incrementBucket(label, by = 1) {
                    post("widget-histogram-increment", { widget: id, label, by });
                },
                push(point) {
                    post("widget-graph-point", { widget: id, point });
                },
                upsertItem(item) {
                    post("widget-list-upsert", { widget: id, item });
                },
                removeItem(itemId) {
                    post("widget-list-remove", { widget: id, item: itemId });
                },
                upsertRow(row) {
                    post("widget-table-upsert", { widget: id, row });
                },
                removeRow(rowId) {
                    post("widget-table-remove", { widget: id, row: rowId });
                },
                setHex(state) {
                    const data = state.bytes instanceof ArrayBuffer ? state.bytes : new Uint8Array(state.bytes).buffer;
                    post("widget-hex-set", { widget: id, hex: { base_address: state.baseAddress ?? 0 } }, data);
                },
                appendConsole(entry) {
                    post("widget-console-append", {
                        widget: id,
                        entry: {
                            id: entry.id ?? makeId(),
                            kind: entry.kind,
                            text: entry.text,
                        },
                    });
                },
                appendOutput(text) {
                    post("widget-console-append", {
                        widget: id,
                        entry: { id: makeId(), kind: "output", text },
                    });
                },
                appendError(text) {
                    post("widget-console-append", {
                        widget: id,
                        entry: { id: makeId(), kind: "error", text },
                    });
                },
                appendValue(value) {
                    const [tree, blob] = encodeValue(value);
                    post("widget-console-append", {
                        widget: id,
                        entry: { id: makeId(), kind: "output", text: "", value: tree },
                    }, blob);
                },
                appendImage(image) {
                    post("widget-console-append", {
                        widget: id,
                        entry: {
                            id: makeId(),
                            kind: "image",
                            text: image.text ?? "",
                            image: { media_type: image.mediaType, width: image.width, height: image.height },
                        },
                    }, consoleImageBuffer(image.bytes));
                },
                setState(value, data) {
                    const [payload, bytes] = viewPayload("state", value, data, viewLimits.stateDataBytes);
                    post("widget-view-state", { widget: id, ...payload, data_size: bytes?.byteLength ?? 0 });
                    for (const piece of viewDataPieces(bytes)) {
                        post("widget-view-state-data", { widget: id }, piece);
                    }
                },
                sendEvent(value, data) {
                    const [payload, bytes] = viewPayload("event", value, data, viewLimits.eventDataBytes);
                    post("widget-view-event", { widget: id, ...payload }, bytes);
                },
                setActionEnabled(action, enabled) {
                    post("widget-action-enabled", { widget: id, action, enabled });
                },
                clear() {
                    post("widget-clear", { widget: id });
                },
            };
        },
    };
}

function viewPayload(kind: string, value: unknown, data: ViewData | null | undefined, maxDataBytes: number): [object, Uint8Array | null] {
    const json = JSON.stringify(value ?? null);
    const jsonBytes = utf8Length(json);
    if (jsonBytes > viewLimits.valueBytes) {
        throw new Error(`A view ${kind} value is ${jsonBytes} bytes of JSON as UTF-8; the most is ${viewLimits.valueBytes}`);
    }
    const bytes = (data === undefined || data === null) ? null : viewDataBytes(data);
    if (bytes !== null && bytes.byteLength > maxDataBytes) {
        throw new Error(`A view ${kind} carries ${bytes.byteLength} bytes of data; the most is ${maxDataBytes}`);
    }
    return [{ json }, bytes];
}

function viewDataPieces(bytes: Uint8Array | null): Uint8Array[] {
    const pieces: Uint8Array[] = [];
    for (let offset = 0; bytes !== null && offset < bytes.byteLength; offset += viewLimits.stateDataPieceBytes) {
        pieces.push(bytes.subarray(offset, offset + viewLimits.stateDataPieceBytes));
    }
    return pieces;
}

function utf8Length(text: string): number {
    let length = 0;
    for (const character of text) {
        const code = character.codePointAt(0)!;
        length += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
    }
    return length;
}

function viewDataBytes(data: ViewData): Uint8Array {
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    return new Uint8Array(data);
}

function consoleImageBuffer(bytes: ArrayBuffer | Uint8Array | number[]): ArrayBuffer {
    if (bytes instanceof ArrayBuffer) return bytes;
    if (bytes instanceof Uint8Array) return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    return new Uint8Array(bytes).buffer;
}

function makeId(): string {
    return Math.random().toString(36).slice(2, 10) + Math.random().toString(36).slice(2, 10);
}
