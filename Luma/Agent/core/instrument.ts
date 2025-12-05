import { encodeValue } from "./value.js";

export interface Instrument<C = unknown> {
    create(
        ctx: InstrumentContext,
        initialConfig: C
    ): InstrumentHandle<C> | Promise<InstrumentHandle<C>>;
}

export interface InstrumentContext {
    instanceId: string;
    emit(payload: unknown): void;
}

export interface InstrumentHandle<C = unknown> {
    updateConfig?(config: C): Promise<void> | void;
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

export async function loadInstrument({ instanceId, moduleName, source, config }: {
    instanceId: string,
    moduleName: string,
    source: string,
    config: unknown,
}): Promise<void> {
    const instrument = await loadInstrumentModule(moduleName, source);
    const ctx = makeInstrumentContext(instanceId);

    const handle = await instrument.create(ctx, config);

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

function makeInstrumentContext(instanceId: string): InstrumentContext {
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
