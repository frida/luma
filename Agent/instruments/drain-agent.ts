import { TraceBuffer, TraceBufferReader } from "frida-itrace";

let reader: TraceBufferReader | null = null;

rpc.exports = {
    openBuffer(location: string) {
        const buffer = TraceBuffer.open(location);
        reader = new TraceBufferReader(buffer);
    },

    drain(): ArrayBuffer | null {
        if (reader === null) {
            return null;
        }
        const chunk = reader.read();
        return chunk.byteLength > 0 ? chunk : null;
    },

    getLost(): number {
        return reader?.lost ?? 0;
    },

    close(): ArrayBuffer | null {
        if (reader === null) {
            return null;
        }
        const chunk = reader.read();
        reader = null;
        return chunk.byteLength > 0 ? chunk : null;
    },
};
