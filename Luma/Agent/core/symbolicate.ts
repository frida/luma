interface ExportEntry {
    address: NativePointer;
    name: string;
}

const exportIndexByModule = new Map<string, ExportEntry[]>();

export function symbolicate(addresses: string[]): (
  | null
  | [string, string]
  | [string, string, string, number]
  | [string, string, string, number, number]
)[] {
    return addresses.map(address => {
        const p = ptr(address);
        const sym = DebugSymbol.fromAddress(p);

        const name = sym.name;
        if (name !== null) {
            const { moduleName, fileName, lineNumber, column } = sym as any;

            if (lineNumber === 0) {
                return [moduleName, name];
            }

            if (column === 0) {
                return [moduleName, name, fileName, lineNumber];
            }

            return [moduleName, name, fileName, lineNumber, column];
        }

        // DebugSymbol failed; fall back to nearest export.
        const nearest = findNearestExport(p);
        if (nearest !== null) {
            return [nearest.moduleName, nearest.symbolName];
        }

        return null;
    });
}

interface NearestExportResult {
    moduleName: string;
    symbolName: string;
}

function findNearestExport(address: NativePointer): NearestExportResult | null {
    const mod = Process.findModuleByAddress(address);
    if (mod === null) {
        return null;
    }

    const exports = getExportIndex(mod);
    if (exports.length === 0) {
        return null;
    }

    // Binary search for the nearest export at or before the address.
    let lo = 0;
    let hi = exports.length - 1;
    let best = -1;

    while (lo <= hi) {
        const mid = (lo + hi) >>> 1;
        if (exports[mid].address.compare(address) <= 0) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }

    if (best === -1) {
        return null;
    }

    const entry = exports[best];
    const offset = address.sub(entry.address).toUInt32();

    return {
        moduleName: mod.name,
        symbolName: offset === 0
            ? entry.name
            : `${entry.name}+0x${offset.toString(16)}`,
    };
}

function getExportIndex(mod: Module): ExportEntry[] {
    const cached = exportIndexByModule.get(mod.path);
    if (cached !== undefined) {
        return cached;
    }

    const entries: ExportEntry[] = mod.enumerateExports()
        .filter(e => e.type === "function")
        .map(e => ({ address: e.address, name: e.name }))
        .sort((a, b) => a.address.compare(b.address));

    exportIndexByModule.set(mod.path, entries);

    return entries;
}
