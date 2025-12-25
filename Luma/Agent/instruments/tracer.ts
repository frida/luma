import type { Instrument, InstrumentContext } from '../core/instrument.js';

interface TracerConfig {
    hooks: TracerHookConfig[];
}

interface TracerHookConfig {
    id: string;
    displayName: string;
    addressAnchor: AddressAnchor;
    isEnabled: boolean;
    code: string;
    isPinned?: boolean;
}

type AddressAnchor =
    | { type: "absolute"; address: string }
    | { type: "moduleOffset"; name: string; offset: number }
    | { type: "moduleExport"; name: string; export: string };

export const instrument: Instrument<TracerConfig> = {
    async create(ctx, initialConfig) {
        let config = initialConfig;
        const hooks = new Map<string, { config: TracerHookConfig; listener: InvocationListener }>();

        function apply(next: TracerConfig) {
            const nextIds = new Set(next.hooks.map(h => h.id));

            for (const [id, runtime] of hooks) {
                if (!nextIds.has(id)) {
                    runtime.listener.detach();
                    hooks.delete(id);
                }
            }

            for (const hook of next.hooks) {
                const existing = hooks.get(hook.id);
                if (existing !== undefined &&
                    existing.config.code === hook.code &&
                    existing.config.isEnabled === hook.isEnabled &&
                    JSON.stringify(existing.config.addressAnchor) === JSON.stringify(hook.addressAnchor)) {
                    continue;
                }

                if (existing !== undefined) {
                    existing.listener.detach();
                    hooks.delete(hook.id);
                }

                if (!hook.isEnabled) {
                    continue;
                }

                const runtime = createHookRuntime(ctx, hook);
                if (runtime !== null) {
                    hooks.set(hook.id, runtime);
                }
            }

            config = next;
        }

        apply(config);

        return {
            async updateConfig(next: TracerConfig) {
                apply(next);
            },
            async dispose() {
                for (const [, runtime] of hooks) {
                    runtime.listener.detach();
                }
                hooks.clear();
            }
        };
    }
};

function createHookRuntime(ctx: InstrumentContext, hook: TracerHookConfig) {
    const target = resolveTarget(hook);
    if (target === null) {
        ctx.emit({
            type: "tracer-error",
            id: hook.id,
            message: "Could not resolve target"
        });
        return null;
    }

    let handler: InvocationListenerCallbacks | InstructionProbeCallback | null = null;

    function defineHandler(h: InvocationListenerCallbacks | InstructionProbeCallback) {
        handler = h;
    }

    const log = (msg: string) =>
        ctx.emit({ type: "tracer-log", id: hook.id, message: msg });

    try {
        const fn = new Function("defineHandler", "log", `"use strict";\n${hook.code}`);
        fn(defineHandler, log);
    } catch (e) {
        ctx.emit({ type: "tracer-error", id: hook.id, message: String(e) });
        return null;
    }

    if (handler === null) {
        throw new Error("Hook did not call defineHandler");
    }

    const listener = Interceptor.attach(target, handler);

    return { config: hook, listener };
}

function resolveTarget(hook: TracerHookConfig): NativePointer | null {
    const anchor = hook.addressAnchor;

    switch (anchor.type) {
        case "absolute": {
            return ptr(anchor.address);
        }

        case "moduleOffset": {
            const m = Process.findModuleByName(anchor.name);
            if (m === null)
                return null;
            return m.base.add(anchor.offset);
        }

        case "moduleExport": {
            const m = Process.findModuleByName(anchor.name);
            if (m === null)
                return null;
            const e = m.findExportByName(anchor.export);
            if (e === null)
                return null;
            return e;
        }

        default:
            return null;
    }
}
