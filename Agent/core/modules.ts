export interface ModuleSymbolBundle {
    exports: ExportEntry[];
    imports: ImportEntry[];
    symbols: SymbolEntry[];
}

export interface ExportEntry {
    type: ModuleExportType;
    name: string;
    address: string;
}

export interface ImportEntry {
    type?: ModuleImportType;
    name: string;
    module?: string;
    address?: string;
    slot?: string;
}

export interface SymbolEntry {
    name: string;
    type: ModuleSymbolType;
    address: string;
    isGlobal: boolean;
    size?: number;
    sectionID?: string;
    sectionProtection?: PageProtection;
}

export interface ModuleRangeEntry {
    offset: string;
    size: number;
    protection: string;
}

export interface ProcessRangeEntry {
    base: string;
    size: number;
    protection: string;
    filePath: string | null;
}

export function enumerateModuleRanges(name: string): ModuleRangeEntry[] {
    const module = Process.getModuleByName(name);
    return module.enumerateRanges('---').map(r => ({
        offset: '0x' + r.base.sub(module.base).toString(16),
        size: r.size,
        protection: r.protection,
    }));
}

export function findRangeByAddress(address: string): ProcessRangeEntry | null {
    const r = Process.findRangeByAddress(ptr(address));
    if (r === null) return null;
    return {
        base: r.base.toString(),
        size: r.size,
        protection: r.protection,
        filePath: r.file ? r.file.path : null,
    };
}

export function getModuleIdentity(name: string): string | null {
    const module = Process.getModuleByName(name);
    const base = module.base;
    const magic = base.readU32();
    if (magic === 0xfeedfacf || magic === 0xfeedface) {
        const ncmds = base.add(magic === 0xfeedfacf ? 16 : 16).readU32();
        const headerSize = magic === 0xfeedfacf ? 32 : 28;
        let cursor = base.add(headerSize);
        for (let i = 0; i < ncmds; i++) {
            const cmd = cursor.readU32();
            const cmdsize = cursor.add(4).readU32();
            if (cmd === 0x1b) {
                const bytes = cursor.add(8).readByteArray(16);
                if (bytes !== null) {
                    return Array.from(new Uint8Array(bytes))
                        .map(b => b.toString(16).padStart(2, '0'))
                        .join('');
                }
            }
            cursor = cursor.add(cmdsize);
        }
    }
    return null;
}

export function enumerateModuleSymbols(name: string): ModuleSymbolBundle {
    const index = getSymbolIndex(name);
    return {
        exports: index.exports.map(e => e.row),
        imports: index.imports.map(e => e.row),
        symbols: index.symbols.map(e => e.row),
    };
}

export type SymbolCategory = "exports" | "imports" | "symbols";

export interface SymbolQueryRequest {
    module: string;
    category: SymbolCategory;
    query: string;
    limit: number;
}

export interface SymbolPage {
    rows: object[];
    matched: number;
    capped: boolean;
    counts: { exports: number; imports: number; symbols: number };
}

export function queryModuleSymbols(request: SymbolQueryRequest): SymbolPage {
    const index = getSymbolIndex(request.module);
    const entries = index[request.category];

    const needle = request.query.toLowerCase();
    const matched = needle === "" ? entries : entries.filter(e => e.key.includes(needle));
    const matchedCount = matched.length;
    const limit = request.limit;
    const capped = matchedCount > limit;
    const page = capped ? matched.slice(0, limit) : matched;

    return {
        rows: page.map(e => e.row),
        matched: matchedCount,
        capped,
        counts: {
            exports: index.exports.length,
            imports: index.imports.length,
            symbols: index.symbols.length,
        },
    };
}

interface IndexedEntry<T> {
    row: T;
    key: string;
}

interface SymbolIndex {
    exports: IndexedEntry<ExportEntry>[];
    imports: IndexedEntry<ImportEntry>[];
    symbols: IndexedEntry<SymbolEntry>[];
}

const symbolIndexCache = new Map<string, SymbolIndex>();

function getSymbolIndex(name: string): SymbolIndex {
    const cached = symbolIndexCache.get(name);
    if (cached !== undefined) {
        return cached;
    }

    const module = Process.getModuleByName(name);
    const index = buildSymbolIndex(module);
    symbolIndexCache.set(name, index);
    return index;
}

function buildSymbolIndex(module: Module): SymbolIndex {
    const exports = module.enumerateExports().map(e => {
        const { type, name, address } = e;
        const addr = address.toString();
        const row: ExportEntry = { type, name, address: addr };
        return indexed(row, [name, type, addr]);
    });

    const imports = module.enumerateImports().map(i => {
        const { name, type, module: origin, address, slot } = i;
        const row: ImportEntry = { name };
        const addr = address?.toString();
        if (type !== undefined) row.type = type;
        if (origin !== undefined) row.module = origin;
        if (addr !== undefined) row.address = addr;
        if (slot !== undefined) row.slot = slot.toString();
        return indexed(row, [name, origin, type, addr]);
    });

    const symbols = module.enumerateSymbols().filter(s => !s.address.isNull()).map(s => {
        const { name, type, address, isGlobal, size, section } = s;
        const addr = address.toString();
        const row: SymbolEntry = { name, type, address: addr, isGlobal };
        if (size !== undefined) row.size = size;
        if (section !== undefined) {
            row.sectionID = section.id;
            row.sectionProtection = section.protection;
        }
        return indexed(row, [name, type, row.sectionID, addr]);
    });

    const byName = (a: { row: { name: string } }, b: { row: { name: string } }) =>
        a.row.name < b.row.name ? -1 : (a.row.name > b.row.name ? 1 : 0);

    return {
        exports: exports.sort(byName),
        imports: imports.sort(byName),
        symbols: symbols.sort(byName),
    };
}

function indexed<T>(row: T, fields: (string | undefined)[]): IndexedEntry<T> {
    return { row, key: fields.filter(f => f !== undefined).join("\x00").toLowerCase() };
}
