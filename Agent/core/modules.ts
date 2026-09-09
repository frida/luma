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

export interface ModuleFunctionEntry {
    offset: number;
    name: string;
    source: "exported" | "symbol";
}

export function enumerateModuleFunctions(name: string): ModuleFunctionEntry[] {
    const index = getModuleIndex(name);
    const { base, size } = index.module;
    const lower = base;
    const upper = base.add(size);

    const functions: ModuleFunctionEntry[] = [];
    const taken = new Set<number>();

    for (const row of collectedRows(index, "exports") as ModuleExportDetails[]) {
        const { address } = row;
        if (row.type !== "function" || address.compare(lower) < 0 || address.compare(upper) >= 0) {
            continue;
        }

        const offset = address.sub(lower).toUInt32();
        taken.add(offset);
        functions.push({ offset, name: row.name, source: "exported" });
    }

    for (const row of collectedRows(index, "symbols") as ModuleSymbolDetails[]) {
        const { address } = row;
        if (!holdsCode(row) || address.compare(lower) <= 0 || address.compare(upper) >= 0) {
            continue;
        }

        const offset = address.sub(lower).toUInt32();
        if (taken.has(offset)) {
            continue;
        }

        taken.add(offset);
        functions.push({ offset, name: row.name, source: "symbol" });
    }

    return functions;
}

function holdsCode(row: ModuleSymbolDetails): boolean {
    const { type, section } = row;

    if (type === "undefined") {
        return false;
    }

    if (type === "function") {
        return true;
    }

    return section?.protection.includes("x") ?? false;
}

export function enumerateModuleSymbols(name: string): ModuleSymbolBundle {
    const index = getModuleIndex(name);
    return {
        exports: reported(index, "exports") as ExportEntry[],
        imports: reported(index, "imports") as ImportEntry[],
        symbols: reported(index, "symbols") as SymbolEntry[],
    };
}

export type SymbolCategory = "exports" | "imports" | "symbols";

export interface SymbolQueryRequest {
    module: string;
    category: SymbolCategory;
    query: string;
    offset: number;
    limit: number;
}

export interface SymbolPage {
    rows: object[];
    matched: number;
    offset: number;
    counts: { exports: number; imports: number; symbols: number };
}

export function queryModuleSymbols(request: SymbolQueryRequest): SymbolPage {
    const index = getModuleIndex(request.module);
    const rows = sortedRows(index, request.category);

    const needle = request.query.toLowerCase();
    const matched = (needle === "") ? rows : rowsMatching(index, request.category, needle);
    const matchedCount = matched.length;
    const offset = Math.max(0, Math.min(request.offset, matchedCount - 1));

    return {
        rows: matched.slice(offset, offset + request.limit)
            .map(row => reportedRow(row, request.category)),
        matched: matchedCount,
        offset,
        counts: {
            exports: collectedRows(index, "exports").length,
            imports: collectedRows(index, "imports").length,
            symbols: collectedRows(index, "symbols").length,
        },
    };
}

type SymbolRow = ModuleExportDetails | ModuleImportDetails | ModuleSymbolDetails;

interface CategoryIndex {
    rows: SymbolRow[];
    sorted?: SymbolRow[];
    searchable?: string[];
}

interface ModuleIndex {
    module: Module;
    categories: Map<SymbolCategory, CategoryIndex>;
}

const moduleIndexCache = new Map<string, ModuleIndex>();

function getModuleIndex(name: string): ModuleIndex {
    let index = moduleIndexCache.get(name);
    if (index === undefined) {
        index = { module: Process.getModuleByName(name), categories: new Map() };
        moduleIndexCache.set(name, index);
    }
    return index;
}

function rowsMatching(index: ModuleIndex, category: SymbolCategory, needle: string): SymbolRow[] {
    const rows = sortedRows(index, category);
    const searchable = searchableText(index, category);

    const matched: SymbolRow[] = [];
    for (let i = 0; i !== rows.length; i++) {
        if (searchable[i].includes(needle)) {
            matched.push(rows[i]);
        }
    }

    return matched;
}

function sortedRows(index: ModuleIndex, category: SymbolCategory): SymbolRow[] {
    const entry = collected(index, category);
    if (entry.sorted !== undefined) {
        return entry.sorted;
    }

    const { rows } = entry;

    const width = String(rows.length).length;
    const decorated = rows.map((row, at) => row.name + "\u0000" + String(at).padStart(width, "0"));
    decorated.sort();

    const sorted: SymbolRow[] = new Array(rows.length);
    for (let i = 0; i !== decorated.length; i++) {
        const decoration = decorated[i];
        sorted[i] = rows[+decoration.slice(decoration.lastIndexOf("\u0000") + 1)];
    }

    entry.sorted = sorted;
    return sorted;
}

function searchableText(index: ModuleIndex, category: SymbolCategory): string[] {
    const entry = collected(index, category);
    if (entry.searchable !== undefined) {
        return entry.searchable;
    }

    const rows = sortedRows(index, category);
    const searchable = new Array<string>(rows.length);
    for (let i = 0; i !== rows.length; i++) {
        searchable[i] = searchableRow(rows[i], category);
    }

    entry.searchable = searchable;
    return searchable;
}

function searchableRow(row: SymbolRow, category: SymbolCategory): string {
    if (category === "exports") {
        const e = row as ModuleExportDetails;
        return (e.name + "\u0000" + e.type + "\u0000" + e.address).toLowerCase();
    }

    if (category === "imports") {
        const i = row as ModuleImportDetails;
        return (i.name + "\u0000" + (i.module ?? "") + "\u0000" + (i.type ?? "") + "\u0000"
            + (i.address ?? "")).toLowerCase();
    }

    const s = row as ModuleSymbolDetails;
    return (s.name + "\u0000" + s.type + "\u0000" + (s.section?.id ?? "") + "\u0000"
        + s.address).toLowerCase();
}

function collectedRows(index: ModuleIndex, category: SymbolCategory): SymbolRow[] {
    return collected(index, category).rows;
}

function collected(index: ModuleIndex, category: SymbolCategory): CategoryIndex {
    let entry = index.categories.get(category);
    if (entry === undefined) {
        entry = { rows: collectRows(index.module, category) };
        index.categories.set(category, entry);
    }
    return entry;
}

function collectRows(module: Module, category: SymbolCategory): SymbolRow[] {
    if (category === "exports") {
        return module.enumerateExports();
    }

    if (category === "imports") {
        const seen = new Set<string>();
        const rows: ModuleImportDetails[] = [];
        for (const row of module.enumerateImports()) {
            const identity = row.name + "\u0000" + (row.module ?? "");
            if (seen.has(identity)) {
                continue;
            }
            seen.add(identity);
            rows.push(row);
        }
        return rows;
    }

    return module.enumerateSymbols().filter(({ address }) => !address.isNull());
}

function reported(index: ModuleIndex, category: SymbolCategory): object[] {
    return sortedRows(index, category).map(row => reportedRow(row, category));
}

function reportedRow(row: SymbolRow, category: SymbolCategory): object {
    if (category === "exports") {
        const { type, name, address } = row as ModuleExportDetails;
        return { type, name, address: address.toString() };
    }

    if (category === "imports") {
        const { name, type, module: origin, address, slot } = row as ModuleImportDetails;
        const reported: ImportEntry = { name };
        if (type !== undefined) reported.type = type;
        if (origin !== undefined) reported.module = origin;
        if (address !== undefined) reported.address = address.toString();
        if (slot !== undefined) reported.slot = slot.toString();
        return reported;
    }

    const { name, type, address, isGlobal, size, section } = row as ModuleSymbolDetails;
    const reported: SymbolEntry = { name, type, address: address.toString(), isGlobal };
    if (size !== undefined) reported.size = size;
    if (section !== undefined) {
        reported.sectionID = section.id;
        reported.sectionProtection = section.protection;
    }
    return reported;
}
