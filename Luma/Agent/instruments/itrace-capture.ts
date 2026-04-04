import {
    TraceBuffer,
    TraceBufferReader,
    TraceSession,
} from "frida-itrace";
import type { InstrumentContext } from "../core/instrument.js";

export interface HookInfo {
    targetAddress: string | null;
    prologueBytes: ArrayBuffer | null;
}

export interface ActiveCapture {
    ctx: InstrumentContext;
    hookId: string;
    callIndex: number;
    hookInfo: HookInfo;
    buffer: TraceBuffer;
    reader: TraceBufferReader;
    session: TraceSession;
}

const activeCaptures = new Map<number, ActiveCapture>();

export function startCapture(
    threadId: number,
    hookId: string,
    callIndex: number,
    ctx: InstrumentContext,
    hookInfo: HookInfo,
): void {
    const buffer = TraceBuffer.create();
    const session = new TraceSession({ type: "thread", threadId }, buffer);
    const reader = new TraceBufferReader(buffer);

    const capture: ActiveCapture = {
        ctx,
        hookId,
        callIndex,
        hookInfo,
        buffer,
        reader,
        session,
    };

    activeCaptures.set(threadId, capture);

    ctx.post("itrace:start", {
        hookId,
        callIndex,
        bufferLocation: buffer.location,
        hookTarget: hookInfo.targetAddress,
        prologueBytes: hookInfo.prologueBytes !== null
            ? arrayBufferToHex(hookInfo.prologueBytes)
            : null,
    });

    session.open();
}

export function stopCapture(threadId: number): void {
    const capture = activeCaptures.get(threadId);
    if (capture === undefined) {
        return;
    }
    activeCaptures.delete(threadId);

    capture.session.close();

    const chunk = capture.reader.read();

    capture.ctx.post("itrace:stop", {
        hookId: capture.hookId,
        callIndex: capture.callIndex,
        lost: capture.reader.lost,
    }, chunk.byteLength > 0 ? chunk : null);
}

export function drainLocally(threadId: number): void {
    const capture = activeCaptures.get(threadId);
    if (capture === undefined) {
        return;
    }

    const chunk = capture.reader.read();
    if (chunk.byteLength > 0) {
        capture.ctx.post("itrace:chunk", {
            hookId: capture.hookId,
            callIndex: capture.callIndex,
            lost: capture.reader.lost,
        }, chunk);
    }
}

function arrayBufferToHex(buf: ArrayBuffer): string {
    return Array.from(new Uint8Array(buf))
        .map(b => b.toString(16).padStart(2, "0"))
        .join("");
}
