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
    push(point: GraphPoint): void;
    upsertItem(item: ListItem): void;
    removeItem(id: string): void;
    clear(): void;
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

export interface WidgetAction {
    widget: string;
    action: string;
    item?: string;
}

export interface InstrumentHandle<C = unknown> {
    updateConfig?(config: C): Promise<void> | void;
    onAction?(action: WidgetAction): Promise<void> | void;
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
                push(point) {
                    post("widget-graph-point", { widget: id, point });
                },
                upsertItem(item) {
                    post("widget-list-upsert", { widget: id, item });
                },
                removeItem(itemId) {
                    post("widget-list-remove", { widget: id, item: itemId });
                },
                clear() {
                    post("widget-clear", { widget: id });
                },
            };
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
