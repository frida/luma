export interface SymbolicateResult {
    module: string;
    name: string;
    offset?: number;
    file?: string;
    line?: number;
    column?: number;
}

interface ExportEntry {
    address: NativePointer;
    name: string;
}

const exportIndexByModule = new Map<string, ExportEntry[]>();

export function symbolicate(addresses: string[]): (SymbolicateResult | null)[] {
    return addresses.map(address => {
        const p = ptr(address);
        const sym = DebugSymbol.fromAddress(p);

        const name = sym.name;
        if (name !== null) {
            return debugSymbolResult(sym, name);
        }

        return nearestExportResult(p);
    });
}

function debugSymbolResult(sym: DebugSymbol, name: string): SymbolicateResult {
    const { moduleName, fileName, lineNumber, column } = sym as DebugSymbol & { column?: number };

    const result: SymbolicateResult = {
        module: moduleName as string,
        name,
    };

    if (lineNumber !== null && lineNumber !== 0) {
        result.file = fileName as string;
        result.line = lineNumber;
        if (column !== undefined && column !== 0) {
            result.column = column;
        }
    }

    return result;
}

function nearestExportResult(address: NativePointer): SymbolicateResult | null {
    const mod = Process.findModuleByAddress(address);
    if (mod === null) {
        return null;
    }

    const exports = getExportIndex(mod);
    if (exports.length === 0) {
        return null;
    }

    const entry = nearestExportAtOrBefore(exports, address);
    if (entry === null) {
        return null;
    }

    const offset = address.sub(entry.address).toUInt32();

    const result: SymbolicateResult = {
        module: mod.name,
        name: entry.name,
    };
    if (offset !== 0) {
        result.offset = offset;
    }
    return result;
}

function nearestExportAtOrBefore(exports: ExportEntry[], address: NativePointer): ExportEntry | null {
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

    return best === -1 ? null : exports[best];
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
