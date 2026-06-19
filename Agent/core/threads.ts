export interface ThreadSnapshot {
    id: ThreadId;
    name: string | null;
    state: ThreadState;
    registers: Array<[string, string]>;
}

export function getThreadSnapshot(id: ThreadId): ThreadSnapshot | null {
    const details = Process.findThreadById(id);
    if (details === null) {
        return null;
    }

    const context = details.context as unknown as { toJSON(): Record<string, NativePointer> };
    const registers: Array<[string, string]> = Object.entries(context.toJSON())
        .map(([name, value]) => [name, value.toString()]);

    return {
        id: details.id,
        name: details.name ?? null,
        state: details.state,
        registers,
    };
}

type ThreadEventBatchMessage = {
    type: "threads-changed";
    added: ThreadInfo[];
    removed: ThreadId[];
    renamed: ThreadRename[];
};

interface ThreadInfo {
    id: ThreadId;
    name?: string;
    entrypoint?: { routine: string; parameter?: string };
}

interface ThreadRename {
    id: ThreadId;
    name: string | null;
}

const addedById = new Map<ThreadId, ThreadInfo>();
const removedIds = new Set<ThreadId>();
const renamedById = new Map<ThreadId, ThreadRename>();

let flushScheduled = false;
let flushGeneration = 0;

Process.attachThreadObserver({
    onAdded(thread) {
        if (removedIds.has(thread.id)) {
            flushNow();
        }
        addedById.set(thread.id, encodeThread(thread));
        scheduleFlush();
    },

    onRemoved(thread) {
        if (addedById.has(thread.id)) {
            addedById.delete(thread.id);
            renamedById.delete(thread.id);
            scheduleFlush();
            return;
        }
        renamedById.delete(thread.id);
        removedIds.add(thread.id);
        scheduleFlush();
    },

    onRenamed(thread) {
        const pending = addedById.get(thread.id);
        if (pending !== undefined) {
            pending.name = thread.name;
            scheduleFlush();
            return;
        }
        renamedById.set(thread.id, { id: thread.id, name: thread.name ?? null });
        scheduleFlush();
    },
});

function flushNow() {
    if (addedById.size === 0 && removedIds.size === 0 && renamedById.size === 0) {
        return;
    }

    const msg: ThreadEventBatchMessage = {
        type: "threads-changed",
        added: Array.from(addedById.values()),
        removed: Array.from(removedIds.values()),
        renamed: Array.from(renamedById.values()),
    };

    addedById.clear();
    removedIds.clear();
    renamedById.clear();

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

function encodeThread(thread: { id: ThreadId; name?: string; entrypoint?: ThreadEntrypoint }): ThreadInfo {
    const info: ThreadInfo = { id: thread.id };
    if (thread.name !== undefined) {
        info.name = thread.name;
    }
    if (thread.entrypoint !== undefined) {
        const ep: ThreadInfo["entrypoint"] = { routine: thread.entrypoint.routine.toString() };
        if (thread.entrypoint.parameter !== undefined) {
            ep.parameter = thread.entrypoint.parameter.toString();
        }
        info.entrypoint = ep;
    }
    return info;
}
