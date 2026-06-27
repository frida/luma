import {
    TraceBuffer,
    TraceBufferReader,
    TraceSession,
    type TraceStrategy,
} from "frida-itrace";

export type Origin =
    | { kind: "functionCall"; hookId: string; callIndex: number }
    | { kind: "thread"; threadId: number; threadName: string | null };

export type DrainMode = "system" | "in-agent";

export type PostMessage = (type: string, payload: object, data?: ArrayBuffer | null) => void;

export interface TraceOptions {
    sessionId: string;
    origin: Origin;
    target: TraceStrategy;
    post: PostMessage;
    maxBytes?: number;
}

export interface StartDetails {
    hookTarget?: string | null;
    prologueBytes?: ArrayBuffer | null;
}

const DRAIN_INTERVAL_MS = 100;

let nextToken = 1;

/**
 * One instruction trace with its own buffer. The buffer is mapped the instant
 * the Trace is constructed, so its location reaches Luma — and Luma can remap
 * it out-of-process — before open() arms Stalker and risks crashing the target.
 */
export class Trace {
    readonly sessionId: string;
    readonly origin: Origin;

    #buffer: TraceBuffer;
    #session: TraceSession;
    #post: PostMessage;
    #maxBytes: number;

    #drainMode: DrainMode = "in-agent";
    #reader: TraceBufferReader | null = null;
    #drainTimer: ReturnType<typeof setInterval> | null = null;
    #bytesDrained = 0;

    constructor(opts: TraceOptions) {
        this.sessionId = opts.sessionId;
        this.origin = opts.origin;
        this.#post = opts.post;
        this.#maxBytes = opts.maxBytes ?? 0;
        this.#buffer = TraceBuffer.create(this.#maxBytes > 0 ? { capacity: this.#maxBytes } : {});
        this.#session = new TraceSession(opts.target, this.#buffer);
    }

    start(details: StartDetails, requestStop: () => void): void {
        this.#drainMode = this.#negotiateDrain(details);
        if (this.#drainMode === "in-agent") {
            this.#reader = new TraceBufferReader(this.#buffer);
            this.#startDrainTimer(requestStop);
        }
        this.#session.open();
    }

    stop(): void {
        if (this.#drainTimer !== null) {
            clearInterval(this.#drainTimer);
            this.#drainTimer = null;
        }

        this.#session.close();

        if (this.#reader !== null) {
            const chunk = this.#reader.read();
            this.#post("itrace:stop", { sessionId: this.sessionId, lost: this.#reader.lost },
                chunk.byteLength > 0 ? chunk : null);
        } else {
            this.#post("itrace:stop", { sessionId: this.sessionId });
        }
    }

    #negotiateDrain(details: StartDetails): DrainMode {
        const token = nextToken++;
        this.#post("itrace:start", {
            token,
            sessionId: this.sessionId,
            origin: this.origin,
            bufferLocation: this.#buffer.location,
            hookTarget: details.hookTarget ?? null,
            prologueBytes: details.prologueBytes ? bufferToHex(details.prologueBytes) : null,
        });

        let drain: DrainMode = "in-agent";
        recv("itrace:ack:" + token, message => {
            if (message.drain === "system" || message.drain === "in-agent") {
                drain = message.drain;
            }
        }).wait();
        return drain;
    }

    #startDrainTimer(requestStop: () => void): void {
        const reader = this.#reader!;
        this.#drainTimer = setInterval(() => {
            const chunk = reader.read();
            if (chunk.byteLength > 0) {
                this.#bytesDrained += chunk.byteLength;
                this.#post("itrace:chunk", { sessionId: this.sessionId, lost: reader.lost }, chunk);
            }
            if (this.#maxBytes > 0 && this.#bytesDrained >= this.#maxBytes) {
                requestStop();
            }
        }, DRAIN_INTERVAL_MS);
    }
}

function bufferToHex(buf: ArrayBuffer): string {
    return Array.from(new Uint8Array(buf))
        .map(b => b.toString(16).padStart(2, "0"))
        .join("");
}
