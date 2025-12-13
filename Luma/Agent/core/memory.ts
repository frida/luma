export function readMemory(address: string, count: number): ArrayBuffer {
    return ptr(address).readByteArray(count)!;
}

Process.attachModuleObserver({
    onAdded(module) {
        send({ type: "module-added", module });
    },
    onRemoved(module) {
        send({ type: "module-removed", module });
    },
});
