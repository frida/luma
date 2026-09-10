type ModuleEventBatchMessage = {
    type: "modules-changed";
    added: Module[];
    removed: Module[];
};

const addedByKey = new Map<string, Module>();
const removedByKey = new Map<string, Module>();

let flushScheduled = false;
let flushGeneration = 0;

export function readMemory(address: string, count: number): ArrayBuffer {
    const bytes = ptr(address).readByteArray(count);
    if (bytes === null) {
        throw new Error(`Nothing mapped at ${address}`);
    }
    return bytes;
}

export function writeMemory(address: string, bytes: ArrayBuffer | number[]): number {
    const buffer = bytes instanceof ArrayBuffer ? new Uint8Array(bytes) : new Uint8Array(bytes);
    ptr(address).writeByteArray(Array.from(buffer));
    return buffer.length;
}

Process.attachModuleObserver({
    onAdded(module) {
        const key = moduleKey(module);

        if (removedByKey.has(key)) {
            flushNow();
        }

        addedByKey.set(key, module);
        scheduleFlush();
    },

    onRemoved(module) {
        const key = moduleKey(module);

        if (addedByKey.has(key)) {
            flushNow();
        }

        removedByKey.set(key, module);
        scheduleFlush();
    },
});

function flushNow() {
    if (addedByKey.size === 0 && removedByKey.size === 0) {
        return;
    }

    const msg: ModuleEventBatchMessage = {
        type: "modules-changed",
        added: Array.from(addedByKey.values()),
        removed: Array.from(removedByKey.values()),
    };

    addedByKey.clear();
    removedByKey.clear();

    flushGeneration++;

    send(msg);
}

function scheduleFlush() {
    if (flushScheduled) {
        return;
    }
    flushScheduled = true;

    const myGen = flushGeneration;

    setImmediate(() => {
        flushScheduled = false;

        if (myGen !== flushGeneration) {
            return;
        }

        flushNow();
    });
}

function moduleKey(m: Module): string {
    return m.base.toString();
}
