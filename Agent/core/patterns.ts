type PatternGlobal = {
    global: string;
    name: string;
    bundle: string;
};

const installedGlobals = new Set<string>();

export async function installPatternGlobals(globals: PatternGlobal[], removed: string[]): Promise<string[]> {
    for (const global of removed) {
        if (installedGlobals.delete(global)) {
            delete (globalThis as any)[global];
        }
    }

    const refused: string[] = [];
    for (const { global, name, bundle } of globals) {
        if (global in globalThis && !installedGlobals.has(global)) {
            refused.push(global);
            continue;
        }
        (globalThis as any)[global] = await Script.load(name, bundle);
        installedGlobals.add(global);
    }
    return refused;
}
