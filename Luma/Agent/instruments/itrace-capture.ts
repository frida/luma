import {
    TraceBuffer,
    TraceBufferReader,
    TraceSession,
    RegisterSpec,
    BlockSpec,
    BlockWriteSpec,
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
    regSpecs: RegisterSpec[];
    blocks: Map<string, BlockSpec>;
    blockBytes: Map<string, ArrayBuffer>;
}

export interface CaptureMetadata {
    hookId: string;
    callIndex: number;
    hookTarget: string | null;
    prologueBytes: string | null;
    regSpecs: RegisterSpec[];
    blocks: SerializedBlockSpec[];
}

interface SerializedBlockSpec {
    name: string;
    address: string;
    size: number;
    bytes: string;
    module?: {
        path: string;
        base: string;
    };
    writes: BlockWriteSpec[];
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
        regSpecs: [],
        blocks: new Map(),
        blockBytes: new Map(),
    };

    session.events.on("start", (regSpecs: RegisterSpec[], _regValues: ArrayBuffer) => {
        capture.regSpecs = regSpecs;
    });

    session.events.on("compile", (block: BlockSpec) => {
        capture.blocks.set(block.address.toString(), block);

        const bytes = block.address.readByteArray(block.size);
        if (bytes !== null) {
            capture.blockBytes.set(block.address.toString(), bytes);
        }
    });

    session.events.on("panic", (message: string) => {
        ctx.emit({
            type: "itrace-panic",
            hookId,
            callIndex,
            message,
        });
    });

    activeCaptures.set(threadId, capture);

    ctx.post("itrace:start", {
        hookId,
        callIndex,
        bufferLocation: buffer.location,
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

    const metadata = serializeMetadata(capture);
    const chunk = capture.reader.read();

    capture.ctx.post("itrace:stop", {
        ...metadata,
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

function serializeMetadata(capture: ActiveCapture): CaptureMetadata {
    const blocks: SerializedBlockSpec[] = [];
    for (const [addrStr, block] of capture.blocks) {
        const bytes = capture.blockBytes.get(addrStr);
        const serialized: SerializedBlockSpec = {
            name: block.name,
            address: addrStr,
            size: block.size,
            bytes: bytes !== undefined ? arrayBufferToHex(bytes) : "",
            writes: block.writes,
        };
        if (block.module !== undefined) {
            serialized.module = {
                path: block.module.path,
                base: block.module.base.toString(),
            };
        }
        blocks.push(serialized);
    }

    return {
        hookId: capture.hookId,
        callIndex: capture.callIndex,
        hookTarget: capture.hookInfo.targetAddress,
        prologueBytes: capture.hookInfo.prologueBytes !== null
            ? arrayBufferToHex(capture.hookInfo.prologueBytes)
            : null,
        regSpecs: capture.regSpecs,
        blocks,
    };
}

function arrayBufferToHex(buf: ArrayBuffer): string {
    return Array.from(new Uint8Array(buf))
        .map(b => b.toString(16).padStart(2, "0"))
        .join("");
}
