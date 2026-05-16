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
    post(type: string, payload: object, data?: ArrayBuffer | number[] | null): void;
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
    clear(): void;
}

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

export interface InstrumentHandle<C = unknown> {
    updateConfig?(config: C): Promise<void> | void;
    onAction?(action: WidgetAction): Promise<void> | void;
    onConsoleInput?(input: ConsoleInput): Promise<void> | void;
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

export async function loadInstrument({ instanceId, moduleName, source, config, restored }: {
    instanceId: string,
    moduleName: string,
    source: string,
    config: unknown,
    restored: unknown,
}): Promise<void> {
    const instrument = await loadInstrumentModule(moduleName, source);
    const ctx = makeInstrumentContext(instanceId);

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

    await controller.handle.onAction?.({ widget, action, item });
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

    await controller.handle.onConsoleInput?.({ widget, entryId, text });
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
    const post = (type: string, payload: object, data?: ArrayBuffer | number[] | null) => {
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
                clear() {
                    post("widget-clear", { widget: id });
                },
            };
        },
    };
}

function makeId(): string {
    return Math.random().toString(36).slice(2, 10) + Math.random().toString(36).slice(2, 10);
}
