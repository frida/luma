import type { Instrument, InstrumentContext } from "../core/instrument.js";

interface CodeShareConfig {
    name: string;
    source: string;
    exports: string[];
}

interface CodeShareGlobalsEvent {
    type: "codeshare-globals";
    names: string[];
}

export const instrument: Instrument<CodeShareConfig> = {
    async create(ctx, initialConfig) {
        const runtime = new CodeShareRuntime(ctx, initialConfig);

        await runtime.load();

        return {
            async updateConfig(next) {
                await runtime.update(next);
            },
            async dispose() {
                await runtime.dispose();
            }
        };
    }
};

class CodeShareRuntime {
    private readonly ctx: InstrumentContext;
    private config: CodeShareConfig;

    private listeners: InvocationListener[] = [];
    private replacedTargets = new Set<NativePointer>();

    constructor(ctx: InstrumentContext, config: CodeShareConfig) {
        this.ctx = ctx;
        this.config = config;
    }

    async load(): Promise<void> {
        const wrapped = makeWrappedSource(this.config.source, this.config.exports);
        this.evaluateWithInterceptorWrapper(wrapped);
        this.emitGlobalsHint();
    }

    async update(next: CodeShareConfig): Promise<void> {
        const sourceChanged = next.source !== this.config.source;
        const exportsChanged = exportsChangedOrLengthDiff(next.exports, this.config.exports);

        this.config = next;

        if (!sourceChanged && !exportsChanged) {
            return;
        }

        await this.dispose();
        await this.load();
    }

    async dispose(): Promise<void> {
        for (const listener of this.listeners) {
            try {
                listener.detach();
            } catch { }
        }
        this.listeners = [];

        for (const target of this.replacedTargets) {
            try {
                Interceptor.revert(target);
            } catch { }
        }
        this.replacedTargets.clear();

        try {
            Interceptor.flush();
        } catch { }

        const g = globalThis as any;
        for (const name of this.config.exports) {
            try {
                delete g[name];
            } catch { }
        }
    }

    private evaluateWithInterceptorWrapper(source: string): void {
        const g = globalThis as any;
        const originalInterceptor = g.Interceptor;

        const runtime = this;
        const wrappedInterceptor: any = { ...originalInterceptor };

        wrappedInterceptor.attach = function (
            target: NativePointerValue,
            callbacksOrProbe: InvocationListenerCallbacks | InstructionProbeCallback,
            data?: NativePointerValue,
        ): InvocationListener {
            const listener = originalInterceptor.attach(target, callbacksOrProbe, data);
            runtime.registerListener(listener);
            return listener;
        };

        wrappedInterceptor.replace = function (
            target: NativePointerValue,
            replacement: NativePointerValue,
            data?: NativePointerValue,
        ): void {
            runtime.registerReplacedTarget(parseNativePointerValue(target));
            return originalInterceptor.replace(target, replacement, data);
        };

        wrappedInterceptor.replaceFast = function (
            target: NativePointerValue,
            replacement: NativePointerValue,
        ): NativePointer {
            const trampoline = originalInterceptor.replaceFast(target, replacement);
            runtime.registerReplacedTarget(parseNativePointerValue(target));
            return trampoline;
        };

        wrappedInterceptor.revert = function (target: NativePointerValue): void {
            runtime.unregisterReplacedTarget(parseNativePointerValue(target));
            return originalInterceptor.revert(target);
        };

        g.Interceptor = wrappedInterceptor;
        try {
            Script.evaluate(this.config.name, source);
        } finally {
            g.Interceptor = originalInterceptor;
        }
    }

    private registerListener(listener: InvocationListener): void {
        this.listeners.push(listener);
    }

    private registerReplacedTarget(target: NativePointer): void {
        this.replacedTargets.add(target);
    }

    private unregisterReplacedTarget(target: NativePointer): void {
        this.replacedTargets.delete(target);
    }

    private emitGlobalsHint(): void {
        const names = this.config.exports;
        if (names.length === 0) {
            return;
        }

        const evt: CodeShareGlobalsEvent = {
            type: "codeshare-globals",
            names
        };
        this.ctx.emit(evt as any);
    }
}

function makeWrappedSource(original: string, exports: string[]): string {
    const exportEntries = exports
        .map(name => `        ${name}`)
        .join(",\n");

    return [
        "(function (global) {",
        original,
        "",
        "const __lumaExports = {",
        exportEntries,
        "};",
        "for (const [k, v] of Object.entries(__lumaExports)) {",
        "    global[k] = __lumaExports[k];",
        "}",
        "})(globalThis);"
    ].join("\n");
}

function exportsChangedOrLengthDiff(a: string[], b: string[]): boolean {
    if (a.length !== b.length)
        return true;
    for (let i = 0; i !== a.length; i++) {
        if (a[i] !== b[i])
            return true;
    }
    return false;
}

function parseNativePointerValue(val: NativePointerValue): NativePointer {
    if (isObjectWrapper(val)) {
        return val.handle;
    }
    return val;
}

function isObjectWrapper(val: NativePointerValue): val is ObjectWrapper {
    return (val as ObjectWrapper).handle !== undefined;
}
