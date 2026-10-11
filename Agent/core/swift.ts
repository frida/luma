import type _Swift from "frida-swift-bridge";
import type { ClassType, EnumType, NominalType, StructType, TypeMember } from "frida-swift-bridge";
import type { AnchorJSON } from "./resolver.js";

export type SwiftTypesOutline =
    | { state: "absent" }
    | { state: "needsBridge" }
    | { state: "available"; types: SwiftTypeEntry[] };

export interface SwiftTypeEntry {
    name: string;
    kind: SwiftTypeKind;
}

export type SwiftTypeKind = "class" | "struct" | "enum" | "protocol";

export interface SwiftTypeDescription {
    name: string;
    kind: SwiftTypeKind;
    superclass: string | null;
    conformances: string[];
    conformers: string[];
    members: SwiftMemberEntry[];
    functions: SwiftFunctionEntry[];
}

export interface SwiftMemberEntry {
    role: SwiftMemberRole;
    name: string;
    typeName: string | null;
}

export type SwiftMemberRole = "field" | "case" | "property" | "staticProperty";

export interface SwiftFunctionEntry {
    name: string;
    address: string;
    anchor: AnchorJSON;
}

export async function outlineSwiftTypes(module: Module): Promise<SwiftTypesOutline> {
    if (!carriesSwiftMetadata(module)) {
        return { state: "absent" };
    }

    const Swift = await findSwiftBridge();
    if (Swift === null) {
        return { state: "needsBridge" };
    }

    return { state: "available", types: enumerateSwiftTypes(Swift, module) };
}

export async function describeSwiftType(module: Module, entry: SwiftTypeEntry): Promise<SwiftTypeDescription> {
    const Swift = await loadSwiftBridge();
    const description = (entry.kind === "protocol")
        ? describeProtocol(Swift, entry)
        : describeNominalType(Swift, entry);
    return { ...description, functions: enumerateTypeFunctions(Swift, module, entry.name) };
}

const SWIFT_METADATA_SECTIONS = new Set([
    "__swift5_types",
    "__swift5_protos",
    "swift5_type_metadata",
    "swift5_protocols",
    ".sw5tymd",
    ".sw5prt",
]);

function carriesSwiftMetadata(module: Module): boolean {
    return module.enumerateSections().some(section => SWIFT_METADATA_SECTIONS.has(section.name));
}

function enumerateSwiftTypes(Swift: typeof _Swift, module: Module): SwiftTypeEntry[] {
    const types: SwiftTypeEntry[] = [];

    for (const facade of Swift.enumerateTypes(module)) {
        const { name, kind } = facade.$type;
        if (kind === "class" || kind === "struct" || kind === "enum") {
            types.push({ name, kind });
        }
    }

    for (const protocol of Swift.enumerateProtocols(module)) {
        types.push({ name: protocol.fullName, kind: "protocol" });
    }

    return types.sort(byKindThenName);
}

function byKindThenName(a: SwiftTypeEntry, b: SwiftTypeEntry): number {
    return (KIND_ORDER.indexOf(a.kind) - KIND_ORDER.indexOf(b.kind)) || a.name.localeCompare(b.name);
}

const KIND_ORDER: SwiftTypeKind[] = ["class", "struct", "enum", "protocol"];

type TypeShape = Omit<SwiftTypeDescription, "functions">;

function describeProtocol(Swift: typeof _Swift, entry: SwiftTypeEntry): TypeShape {
    const protocol = Swift.Protocol.find(entry.name);
    if (protocol === null) {
        throw new Error(`Swift protocol ${entry.name} is no longer loaded`);
    }

    return {
        ...entry,
        superclass: null,
        conformances: [],
        conformers: protocol.conformingTypes().map(type => type.name).sort(),
        members: [],
    };
}

function describeNominalType(Swift: typeof _Swift, entry: SwiftTypeEntry): TypeShape {
    const facade = Swift.type(entry.name);
    if (facade === null) {
        throw new Error(`Swift type ${entry.name} is no longer loaded`);
    }
    const type = facade.$type as NominalType;

    return {
        ...entry,
        superclass: (entry.kind === "class") ? (type as ClassType).superClass?.name ?? null : null,
        conformances: Object.keys(type.protocols()).sort(),
        conformers: [],
        members: membersOf(type, entry.kind),
    };
}

function membersOf(type: NominalType, kind: SwiftTypeKind): SwiftMemberEntry[] {
    const stored = storedMembers(type, kind);
    const storedNames = new Set(stored.map(member => member.name));
    const computed = properties(type).filter(property => property.role === "staticProperty" || !storedNames.has(property.name));
    return [...stored, ...computed];
}

function storedMembers(type: NominalType, kind: SwiftTypeKind): SwiftMemberEntry[] {
    switch (kind) {
        case "struct":
            return (type as StructType).fields.map(member => memberEntry("field", member));
        case "enum":
            return (type as EnumType).cases.map(member => memberEntry("case", member));
        default:
            return [];
    }
}

function memberEntry(role: SwiftMemberRole, { name, type }: TypeMember): SwiftMemberEntry {
    return { role, name, typeName: type?.name ?? null };
}

function properties(type: NominalType): SwiftMemberEntry[] {
    return type.properties().map(({ name, typeName, isStatic }) => ({
        role: isStatic ? "staticProperty" : "property",
        name,
        typeName,
    }));
}

function enumerateTypeFunctions(Swift: typeof _Swift, module: Module, typeName: string): SwiftFunctionEntry[] {
    const resolver = new ApiResolver("swift");
    const nestedTypePrefixes = nestedTypeNames(Swift, module, typeName).map(name => `${name}.`);
    const qualifier = `${typeName}.`;

    const functions: SwiftFunctionEntry[] = [];
    for (const prefix of ["", "static "]) {
        for (const { name, address } of resolver.enumerateMatches(`functions:${module.path}!${prefix}${qualifier}*`)) {
            const qualifiedName = name.substring(name.indexOf("!") + 1);
            const memberName = qualifiedName.substring(prefix.length + qualifier.length);
            if (nestedTypePrefixes.some(nested => memberName.startsWith(nested))) {
                continue;
            }
            functions.push({
                name: prefix + memberName,
                address: address.toString(),
                anchor: { type: "swiftFunc", module: module.path, function: qualifiedName },
            });
        }
    }

    return withoutSlotAliases(functions).sort((a, b) => a.name.localeCompare(b.name));
}

function nestedTypeNames(Swift: typeof _Swift, module: Module, typeName: string): string[] {
    const qualifier = `${typeName}.`;
    return enumerateSwiftTypes(Swift, module)
        .filter(({ name }) => name.startsWith(qualifier))
        .map(({ name }) => name.substring(qualifier.length));
}

function withoutSlotAliases(functions: SwiftFunctionEntry[]): SwiftFunctionEntry[] {
    const namedAddresses = new Set(functions.filter(f => !isSlotName(f.name)).map(f => f.address));
    return functions.filter(f => !isSlotName(f.name) || !namedAddresses.has(f.address));
}

function isSlotName(name: string): boolean {
    return /^(vtable|overrides)\[\d+\]$/.test(name);
}

async function loadSwiftBridge(): Promise<typeof _Swift> {
    const bridge = await findSwiftBridge();
    if (bridge === null) {
        throw new Error("The 'frida-swift-bridge' package is required for Swift types.");
    }
    return bridge;
}

async function findSwiftBridge(): Promise<typeof _Swift | null> {
    if (cachedSwiftBridge !== null) {
        return cachedSwiftBridge;
    }

    try {
        const mod = await import("frida-swift-bridge");
        cachedSwiftBridge = (mod as any).default ?? mod;
    } catch (e) {
        return null;
    }

    return cachedSwiftBridge;
}

let cachedSwiftBridge: typeof _Swift | null = null;
