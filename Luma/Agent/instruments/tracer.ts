import type { Instrument, InstrumentContext } from '../core/instrument.js';

interface TracerHookConfig {
    id: string;
    displayName: string;
    moduleName?: string;
    symbolName?: string;
    isEnabled: boolean;
    code: string;
    isPinned?: boolean;
}

interface TracerConfig {
    hooks: TracerHookConfig[];
}

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
                if (existing !== undefined && existing.config.code === hook.code && existing.config.isEnabled === hook.isEnabled) {
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
}

function createHookRuntime(ctx: InstrumentContext, hook: TracerHookConfig) {
    const target = resolveTarget(hook);
    if (target === null) {
        ctx.emit({ type: "tracer-error", id: hook.id, message: "Could not resolve symbol" });
        return null;
    }

    let onEnter: any = null;
    let onLeave: any = null;

    function defineHandler(def: { onEnter?: any; onLeave?: any }) {
        onEnter = def.onEnter ?? null;
        onLeave = def.onLeave ?? null;
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

    const listener = Interceptor.attach(target, { onEnter, onLeave });

    return { config: hook, listener };
}

function resolveTarget(hook: TracerHookConfig): NativePointer | null {
    const { moduleName, symbolName } = hook;

    if (moduleName !== undefined && symbolName !== undefined) {
        const m = Process.findModuleByName(moduleName);
        if (m === null)
            return null;
        const e = m.findExportByName(symbolName);
        if (e === null)
            return null;
        return e;
    }

    if (symbolName !== undefined) {
        const sym = DebugSymbol.fromName(symbolName);
        if (sym.name === null)
            return null;
        return sym.address;
    }

    return null;
}
