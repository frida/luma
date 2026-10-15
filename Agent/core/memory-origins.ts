type MemoryReader = "readByteArray" | "readVolatile";

const memoryReaders: MemoryReader[] = ["readByteArray", "readVolatile"];
const origins = new WeakMap<object, NativePointer>();

memoryReaders.forEach(recordReads);

export function addressOfBytes(binary: ArrayBuffer | ArrayBufferView): string | null {
    const buffer = ArrayBuffer.isView(binary) ? binary.buffer : binary;
    const origin = origins.get(buffer);
    if (origin === undefined) {
        return null;
    }
    const offset = ArrayBuffer.isView(binary) ? binary.byteOffset : 0;
    return origin.add(offset).toString();
}

function recordReads(reader: MemoryReader): void {
    const proto = NativePointer.prototype;
    const original = proto[reader];

    proto[reader] = function (this: NativePointer, length: number): ArrayBuffer | null {
        const buffer = original.call(this, length);
        if (buffer !== null) {
            origins.set(buffer, this);
        }
        return buffer;
    };
}
