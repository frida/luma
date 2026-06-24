import type _Java from "frida-java-bridge";
import type { Instrument, InstrumentContext } from '../core/instrument.js';
import { loadJavaBridge, resolveAnchor, type AnchorJSON } from '../core/resolver.js';
import { Trace } from '../core/itrace.js';

interface TracerConfig {
    hooks: TracerHookConfig[];
    threadTraces?: ThreadTraceConfig[];
    callCounters?: Record<string, number>;
}

interface ThreadTraceConfig {
    id: string;
    threadId: number;
    threadName: string | null;
}

type HookState = "enabled" | "disabled";

interface TracerHookConfig {
    id: HookID;
    displayName: string;
    addressAnchor: AnchorJSON;
    state: HookState;
    code: string;
    itraceArming?: ITraceArming;
}

interface ITraceArming {
    maxInvocations: number;
    maxBytesPerInvocation: number;
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
    #activeTraces = new Map<string, Trace>();
    #post: (type: string, payload: object, data?: ArrayBuffer | null) => void;
    #started = Date.now();

    constructor(ctx: InstrumentContext, config: TracerConfig) {
        this.#ctx = ctx;
        this.#config = config;
        this.#post = ctx.post;

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

        for (const sessionId of [...this.#activeTraces.keys()]) {
            this.#stopTrace(sessionId);
        }
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
                // A hook's target address can't change via update_tracer_hook/edit_tracer_hook
                // (only its code/state/itraceArming can), so the interceptor attachment never
                // needs to move. Reconcile in place whenever the handler code and enabled-state
                // are unchanged — re-attaching would make the interceptor relocate its own live
                // redirect as if it were the original prologue, dereferencing the function's own
                // bytes as a pointer (crash). The handler reads hook config fresh on every call,
                // so swapping it in place is sufficient. (Deliberately not comparing addressAnchor:
                // it is immutable for an existing id and re-serialization can spuriously differ.)
                const attachmentUnchanged =
                    config.code === hookConfig.code &&
                    config.state === hookConfig.state;
                if (attachmentUnchanged) {
                    existing[1] = hookConfig;
                    continue;
                }

                existing[0]();
                hooks.delete(hookConfig.id);
            }

            if (hookConfig.state !== "enabled") {
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

        this.#applyThreadTraces(next.threadTraces ?? []);

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

        const resolved = resolveAnchor(hookConfig.addressAnchor);
        if (resolved === null) {
            throw new Error("Could not resolve target");
        }
        const target = resolved.strip();

        this.#hookTargets.set(hookConfig.id, target);

        // Snapshot the pristine prologue before the interceptor redirects the entry, so itrace
        // arming can hand the original bytes to the backend even when arming is toggled on after
        // the hook is already live. Captured once per target so a later re-attach never overwrites
        // it with an already-redirected prologue.
        const targetKey = target.toString();
        if (!this.#prologueBackups.has(targetKey)) {
            const backup = target.readByteArray(64);
            if (backup !== null) {
                this.#prologueBackups.set(targetKey, backup);
            }
        }

        if (typeof handler === "function") {
            return this.#attachNativeInstructionHook(hookConfig, target, handler);
        }
        return this.#attachNativeFunctionHook(hookConfig, target, handler);
    }

    #attachNativeFunctionHook(hookConfig: TracerHookConfig, target: NativePointer, handlers: FunctionHandlers): FunctionHook {
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

                const arming = config.itraceArming;
                if (arming !== undefined) {
                    const callIndex = tracer.#callCounters.get(config.id) ?? 0;
                    if (arming.maxInvocations < 0 || callIndex < arming.maxInvocations) {
                        tracer.#callCounters.set(config.id, callIndex + 1);
                        const target = tracer.#hookTargets.get(config.id);
                        const prologueBackup = target !== undefined
                            ? tracer.#prologueBackups.get(target.toString()) ?? null
                            : null;
                        const sessionId = `${config.id}:${callIndex}`;
                        const trace = new Trace({
                            sessionId,
                            origin: { kind: "functionCall", hookId: config.id, callIndex },
                            target: { type: "thread", threadId: this.threadId },
                            post: tracer.#post,
                            maxBytes: arming.maxBytesPerInvocation,
                        });
                        tracer.#activeTraces.set(sessionId, trace);
                        (this as any)._itraceSessionId = sessionId;
                        trace.start(
                            { hookTarget: target?.toString() ?? null, prologueBytes: prologueBackup },
                            () => tracer.#stopTrace(sessionId));
                    }
                }

                tracer.#invokeNativeHandler(onEnter, config, this, args, ">");
            },
            onLeave(retval) {
                const [_, config, __, onLeave] = hook;
                tracer.#invokeNativeHandler(onLeave, config, this, retval, "<");

                const sessionId = (this as any)._itraceSessionId as string | undefined;
                if (sessionId !== undefined) {
                    tracer.#stopTrace(sessionId);
                    (this as any)._itraceSessionId = undefined;
                }
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

    #applyThreadTraces(next: ThreadTraceConfig[]) {
        const desired = new Set(next.map(t => t.id));

        for (const [sessionId, trace] of this.#activeTraces) {
            if (trace.origin.kind === "thread" && !desired.has(sessionId)) {
                this.#stopTrace(sessionId);
            }
        }

        for (const config of next) {
            if (this.#activeTraces.has(config.id)) {
                continue;
            }
            const trace = new Trace({
                sessionId: config.id,
                origin: { kind: "thread", threadId: config.threadId, threadName: config.threadName },
                target: { type: "thread", threadId: config.threadId },
                post: this.#post,
            });
            this.#activeTraces.set(config.id, trace);
            trace.start({}, () => this.#stopTrace(config.id));
        }
    }

    #stopTrace(sessionId: string) {
        const trace = this.#activeTraces.get(sessionId);
        if (trace === undefined) {
            return;
        }
        this.#activeTraces.delete(sessionId);
        trace.stop();
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
