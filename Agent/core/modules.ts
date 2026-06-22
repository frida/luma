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
    const module = Process.getModuleByName(name);

    return {
        exports: module.enumerateExports().map(e => ({
            type: e.type,
            name: e.name,
            address: e.address.toString(),
        })),
        imports: module.enumerateImports().map(i => {
            const out: ImportEntry = { name: i.name };
            if (i.type !== undefined) out.type = i.type;
            if (i.module !== undefined) out.module = i.module;
            if (i.address !== undefined) out.address = i.address.toString();
            if (i.slot !== undefined) out.slot = i.slot.toString();
            return out;
        }),
        symbols: module.enumerateSymbols().filter(s => !s.address.isNull()).map(s => {
            const out: SymbolEntry = {
                name: s.name,
                type: s.type,
                address: s.address.toString(),
                isGlobal: s.isGlobal,
            };
            if (s.size !== undefined) out.size = s.size;
            if (s.section !== undefined) {
                out.sectionID = s.section.id;
                out.sectionProtection = s.section.protection;
            }
            return out;
        }),
    };
}
