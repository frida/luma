import type _Java from "frida-java-bridge";
import type { Instrument, InstrumentContext } from '../core/instrument.js';
import { loadJavaBridge, resolveAnchor, type AnchorJSON } from '../core/resolver.js';
import { startCapture, stopCapture } from './itrace-capture.js';

interface TracerConfig {
    hooks: TracerHookConfig[];
    callCounters?: Record<string, number>;
}

interface TracerHookConfig {
    id: HookID;
    displayName: string;
    addressAnchor: AnchorJSON;
    isEnabled: boolean;
    code: string;
    isPinned?: boolean;
    itraceEnabled?: boolean;
}

type HookID = string;

type Handler = FunctionHandlers | InstructionHandler;

interface FunctionHandlers {
    onEnter?: EnterHandler;
    onLeave?: LeaveHandler;
}

type Hook = FunctionHook | InstructionHook | JavaHook;
type FunctionHook = [detach: () => void, config: TracerHookConfig, onEnter: EnterHandler, onLeave: LeaveHandler, kind: "function"];
type InstructionHook = [detach: () => void, config: TracerHookConfig, onHit: InstructionHandler, kind: "instruction"];
type JavaHook = [detach: () => void, config: TracerHookConfig, onEnter: JavaEnterHandler, onLeave: JavaLeaveHandler, kind: "java"];
type EnterHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
type LeaveHandler = (this: InvocationContext, log: LogHandler, retval: InvocationReturnValue) => any;
type InstructionHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
type JavaEnterHandler = (this: any, log: LogHandler, args: any[]) => void;
type JavaLeaveHandler = (this: any, log: LogHandler, retval: any) => any;
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
            hook[0]();
        }
        this.#hooks.clear();
    }

    async updateConfig(next: TracerConfig) {
        await this.#apply(next);
    }

    async #apply(next: TracerConfig) {
        const ctx = this.#ctx;
        const hooks = this.#hooks;

        const nextIds = new Set(next.hooks.map(h => h.id));

        for (const [id, runtime] of hooks) {
            if (!nextIds.has(id)) {
                runtime[0]();
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
                existing[0]();
                hooks.delete(hookConfig.id);
            }

            if (!hookConfig.isEnabled) {
                continue;
            }

            try {
                hooks.set(hookConfig.id, await this.#attachHook(hookConfig));
            } catch (e) {
                this.#ctx.emit({
                    type: "tracer-error",
                    id: hookConfig.id,
                    message: (e instanceof Error) ? e.message : "Could not resolve target"
                });
            }
        }

        this.#config = next;
    }

    async #attachHook(hookConfig: TracerHookConfig): Promise<Hook> {
        const handler = compileHandler(hookConfig.code);

        if (hookConfig.addressAnchor.type === "javaMethod") {
            if (typeof handler === "function") {
                throw new Error("Java hooks require onEnter/onLeave handlers");
            }
            return this.#attachJavaHook(hookConfig, hookConfig.addressAnchor, handler);
        }

        const target = resolveAnchor(hookConfig.addressAnchor);
        if (target === null) {
            throw new Error("Could not resolve target");
        }

        this.#hookTargets.set(hookConfig.id, target);

        if (typeof handler === "function") {
            return this.#attachNativeInstructionHook(hookConfig, target, handler);
        }
        return this.#attachNativeFunctionHook(hookConfig, target, handler);
    }

    #attachNativeFunctionHook(hookConfig: TracerHookConfig, target: NativePointer, handlers: FunctionHandlers): FunctionHook {
        if (hookConfig.itraceEnabled) {
            const backup = target.readByteArray(64);
            if (backup !== null) {
                this.#prologueBackups.set(target.toString(), backup);
            }
        }

        const hook: FunctionHook = [
            () => { },
            hookConfig,
            handlers.onEnter ?? noop,
            handlers.onLeave ?? noop,
            "function",
        ];
        const listener = Interceptor.attach(target, this.#makeNativeFunctionListener(hook));
        hook[0] = () => listener.detach();
        return hook;
    }

    #attachNativeInstructionHook(hookConfig: TracerHookConfig, target: NativePointer, onHit: InstructionHandler): InstructionHook {
        const hook: InstructionHook = [
            () => { },
            hookConfig,
            onHit,
            "instruction",
        ];
        const listener = Interceptor.attach(target, this.#makeNativeInstructionListener(hook));
        hook[0] = () => listener.detach();
        return hook;
    }

    async #attachJavaHook(hookConfig: TracerHookConfig, anchor: JavaMethodAnchor, handlers: FunctionHandlers): Promise<JavaHook> {
        const Java = await loadJavaBridge();

        const hook: JavaHook = [
            () => { },
            hookConfig,
            handlers.onEnter ?? noop,
            handlers.onLeave ?? noop,
            "java",
        ];

        const overloads: _Java.Method[] = [];
        Java.perform(() => {
            const klass = Java.use(anchor.className);
            const dispatcher = klass[anchor.methodName];
            if (dispatcher === undefined) {
                throw new Error(`Method '${anchor.methodName}' not found on '${anchor.className}'`);
            }
            for (const method of dispatcher.overloads) {
                method.implementation = this.#makeJavaImplementation(hook, method);
                overloads.push(method);
            }
        });

        hook[0] = () => {
            Java.perform(() => {
                for (const method of overloads) {
                    method.implementation = null;
                }
            });
        };

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

    #makeJavaImplementation(hook: JavaHook, method: _Java.Method): _Java.MethodImplementation {
        const tracer = this;
        return function (...args: any[]) {
            const [, config, onEnter, onLeave] = hook;
            tracer.#invokeJavaHandler(onEnter, config, this, args, ">");
            const retval = method.apply(this, args);
            const replacement = tracer.#invokeJavaHandler(onLeave, config, this, retval, "<");
            return (replacement !== undefined) ? replacement : retval;
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

    #invokeJavaHandler(callback: JavaEnterHandler | JavaLeaveHandler, config: TracerHookConfig,
        context: any, param: any, cutPoint: CutPoint): any {
        const threadId = Process.getCurrentThreadId();
        const depth = this.#updateDepth(threadId, cutPoint);

        const timestamp = Date.now() - this.#started;

        const log = (...message: any[]) => {
            this.#ctx.emit([config.id, timestamp, threadId, depth, NULL, [], message]);
        };

        return callback.call(context, log, param);
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

function compileHandler(code: string): Handler {
    let handler: Handler | null = null;

    function defineHandler(h: Handler) {
        handler = h;
    }

    const fn = new Function("defineHandler", `"use strict";\n${code}`);
    fn(defineHandler);

    if (handler === null) {
        throw new Error("Hook did not call defineHandler");
    }
    return handler;
}

type JavaMethodAnchor = Extract<AnchorJSON, { type: "javaMethod" }>;

function noop() {
}
