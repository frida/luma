import type { Instrument, InstrumentContext } from '../core/instrument.js';
import { startCapture, stopCapture } from './itrace-capture.js';

interface TracerConfig {
    hooks: TracerHookConfig[];
    callCounters?: Record<string, number>;
}

interface TracerHookConfig {
    id: HookID;
    displayName: string;
    addressAnchor: AddressAnchor;
    isEnabled: boolean;
    code: string;
    isPinned?: boolean;
    itraceEnabled?: boolean;
}

type HookID = string;

type AddressAnchor =
    | { type: "absolute"; address: string }
    | { type: "moduleOffset"; name: string; offset: number }
    | { type: "moduleExport"; name: string; export: string };

type Handler = FunctionHandlers | InstructionHandler;

interface FunctionHandlers {
    onEnter?: EnterHandler;
    onLeave?: LeaveHandler;
}

type Hook = FunctionHook | InstructionHook;
type FunctionHook = [listener: InvocationListener, config: TracerHookConfig, onEnter: EnterHandler, onLeave: LeaveHandler];
type InstructionHook = [listener: InvocationListener, config: TracerHookConfig, onHit: InstructionHandler];
type EnterHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
type LeaveHandler = (this: InvocationContext, log: LogHandler, retval: InvocationReturnValue) => any;
type InstructionHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
type LogHandler = (...args: any[]) => void;
type CutPoint = ">" | "|" | "<";

export const instrument: Instrument<TracerConfig> = {
    async create(ctx, initialConfig) {
        return new Tracer(ctx, initialConfig);
    }
};

class Tracer {
    #ctx: InstrumentContext;
    #config: TracerConfig;

    #hooks = new Map<string, Hook>();
    #hookTargets = new Map<string, NativePointer>();
    #prologueBackups = new Map<string, ArrayBuffer>();
    #stackDepth = new Map<ThreadId, number>();
    #callCounters = new Map<string, number>();
    #started = Date.now();

    constructor(ctx: InstrumentContext, config: TracerConfig) {
        this.#ctx = ctx;
        this.#config = config;

        if (config.callCounters !== undefined) {
            for (const [id, count] of Object.entries(config.callCounters)) {
                this.#callCounters.set(id, count);
            }
        }

        this.#apply(config);
    }

    async dispose() {
        for (const [, hook] of this.#hooks) {
            hook[0].detach();
        }
        this.#hooks.clear();
    }

    async updateConfig(next: TracerConfig) {
        this.#apply(next);
    }

    #apply(next: TracerConfig) {
        const ctx = this.#ctx;
        const hooks = this.#hooks;

        const nextIds = new Set(next.hooks.map(h => h.id));

        for (const [id, runtime] of hooks) {
            if (!nextIds.has(id)) {
                runtime[0].detach();
                hooks.delete(id);
            }
        }

        for (const hookConfig of next.hooks) {
            const existing = hooks.get(hookConfig.id);
            if (existing !== undefined) {
                const config = existing[1];
                if (config.code === hookConfig.code &&
                    config.isEnabled === hookConfig.isEnabled &&
                    config.itraceEnabled === hookConfig.itraceEnabled &&
                    JSON.stringify(config.addressAnchor) === JSON.stringify(hookConfig.addressAnchor)) {
                    continue;
                }
            }

            if (existing !== undefined) {
                existing[0].detach();
                hooks.delete(hookConfig.id);
            }

            if (!hookConfig.isEnabled) {
                continue;
            }

            try {
                hooks.set(hookConfig.id, this.#attachHook(hookConfig));
            } catch (e) {
                this.#ctx.emit({
                    type: "tracer-error",
                    id: hookConfig.id,
                    message: "Could not resolve target"
                });
            }
        }

        this.#config = next;
    }

    #attachHook(hookConfig: TracerHookConfig): Hook {
        const target = resolveTarget(hookConfig);
        if (target === null) {
            throw new Error("Could not resolve target");
        }

        let handler: Handler | null = null;

        function defineHandler(h: Handler) {
            handler = h;
        }

        const fn = new Function("defineHandler", `"use strict";\n${hookConfig.code}`);
        fn(defineHandler);

        if (handler === null) {
            throw new Error("Hook did not call defineHandler");
        }

        let hook: Hook;
        if (typeof handler === "function") {
            const cb: InstructionHandler = handler;
            hook = [null as unknown as InvocationListener, hookConfig, cb] as InstructionHook;
        } else {
            const cbs: FunctionHandlers = handler;
            hook = [null as unknown as InvocationListener, hookConfig, cbs.onEnter ?? noop, cbs.onLeave ?? noop] as FunctionHook;
        }

        this.#hookTargets.set(hookConfig.id, target);

        // Back up prologue bytes before Interceptor overwrites them.
        if (hook.length === 4 && hookConfig.itraceEnabled) {
            const backup = target.readByteArray(64);
            if (backup !== null) {
                this.#prologueBackups.set(target.toString(), backup);
            }
        }

        const listener = Interceptor.attach(target, (hook.length === 3)
            ? this.#makeNativeInstructionListener(hook)
            : this.#makeNativeFunctionListener(hook));
        hook[0] = listener;

        return hook;
    }

    #makeNativeFunctionListener(hook: FunctionHook): InvocationListenerCallbacks {
        const tracer = this;

        return {
            onEnter(args) {
                const [_, config, onEnter, __] = hook;

                if (config.itraceEnabled) {
                    const callIndex = tracer.#nextCallIndex(config.id);
                    const target = tracer.#hookTargets.get(config.id);
                    const prologueBackup = target !== undefined
                        ? tracer.#prologueBackups.get(target.toString()) ?? null
                        : null;
                    startCapture(this.threadId, config.id, callIndex, tracer.#ctx, {
                        targetAddress: target?.toString() ?? null,
                        prologueBytes: prologueBackup,
                    });
                }

                tracer.#invokeNativeHandler(onEnter, config, this, args, ">");
            },
            onLeave(retval) {
                const [_, config, __, onLeave] = hook;
                tracer.#invokeNativeHandler(onLeave, config, this, retval, "<");

                stopCapture(this.threadId);
            }
        };
    }

    #makeNativeInstructionListener(hook: InstructionHook): InstructionProbeCallback {
        const agent = this;

        return function (args) {
            const [_, config, onHit] = hook;
            agent.#invokeNativeHandler(onHit, config, this, args, "|");
        };
    }

    #invokeNativeHandler(callback: EnterHandler | LeaveHandler | InstructionHandler, config: TracerHookConfig,
        context: InvocationContext, param: any, cutPoint: CutPoint) {
        const threadId = context.threadId;
        const depth = this.#updateDepth(threadId, cutPoint);

        const timestamp = Date.now() - this.#started;
        const caller = context.returnAddress;
        const backtrace = Thread.backtrace(context.context);

        const log = (...message: any[]) => {
            this.#ctx.emit([config.id, timestamp, threadId, depth, caller, backtrace, message]);
        };

        callback.call(context, log, param);
    }

    #nextCallIndex(hookId: string): number {
        const current = this.#callCounters.get(hookId) ?? 0;
        this.#callCounters.set(hookId, current + 1);
        return current;
    }

    #updateDepth(threadId: ThreadId, cutPoint: CutPoint): number {
        const depthEntries = this.#stackDepth;

        let depth = depthEntries.get(threadId) ?? 0;
        if (cutPoint === ">") {
            depthEntries.set(threadId, depth + 1);
        } else if (cutPoint === "<") {
            depth--;
            if (depth !== 0) {
                depthEntries.set(threadId, depth);
            } else {
                depthEntries.delete(threadId);
            }
        }

        return depth;
    }
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

function noop() {
}
