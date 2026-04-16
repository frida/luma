import type _Java from "frida-java-bridge";

export interface ResolveRequest {
    scope: TargetScope;
    query: string;
}

export type TargetScope =
    | "function"
    | "module"
    | "imports"
    | "relative-function"
    | "absolute-instruction"
    | "objc-method"
    | "swift-func"
    | "java-method"
    | "debug-symbol";

export interface ResolvedTarget {
    scope: TargetScope;
    displayName: string;
    detail: string | null;
    address: string;
    anchor: AnchorJSON;
}

export type AnchorJSON =
    | { type: "absolute"; address: string }
    | { type: "moduleOffset"; name: string; offset: number }
    | { type: "moduleExport"; name: string; export: string }
    | { type: "objcMethod"; selector: string }
    | { type: "swiftFunc"; module: string; function: string }
    | { type: "javaMethod"; className: string; methodName: string }
    | { type: "debugSymbol"; name: string };

export async function resolveTargets(request: ResolveRequest): Promise<ResolvedTarget[]> {
    const { scope, query } = request;

    switch (scope) {
        case "function":
            return resolveFunctionScope(query);

        case "module":
            return resolveModuleScope(query);

        case "imports":
            return resolveImportsScope(query);

        case "relative-function":
            return resolveRelativeFunctionScope(query);

        case "absolute-instruction":
            return resolveAbsoluteInstructionScope(query);

        case "objc-method":
            return resolveObjcMethodScope(query);

        case "swift-func":
            return resolveSwiftFuncScope(query);

        case "java-method":
            return await resolveJavaMethodScope(query);

        case "debug-symbol":
            return resolveDebugSymbolScope(query);
    }
}

export async function lookupAnchorAddress(anchor: AnchorJSON): Promise<string | null> {
    return resolveAnchor(anchor)?.toString() ?? null;
}

export function resolveAnchor(anchor: AnchorJSON): NativePointer | null {
    switch (anchor.type) {
        case "absolute":
            return ptr(anchor.address);

        case "moduleOffset": {
            const module = Process.findModuleByName(anchor.name);
            return module?.base.add(anchor.offset) ?? null;
        }

        case "moduleExport": {
            const module = Process.findModuleByName(anchor.name);
            return module?.findExportByName(anchor.export) ?? null;
        }

        case "objcMethod":
            return firstMatchAddress(getObjcResolver().enumerateMatches(anchor.selector));

        case "swiftFunc":
            return firstMatchAddress(
                getSwiftResolver().enumerateMatches(`functions:${anchor.module}!${anchor.function}`)
            );

        case "debugSymbol": {
            const matches = DebugSymbol.findFunctionsMatching(anchor.name);
            return matches.length > 0 ? matches[0] : null;
        }

        case "javaMethod":
            return null;
    }
}

function resolveFunctionScope(query: string): ResolvedTarget[] {
    const pattern = query.includes("!") ? query : `*!${query}`;
    return getModuleResolver()
        .enumerateMatches(`exports:${pattern}`)
        .map(moduleExportTargetFromMatch);
}

function resolveModuleScope(query: string): ResolvedTarget[] {
    return getModuleResolver()
        .enumerateMatches(`exports:${query}!*`)
        .map(moduleExportTargetFromMatch);
}

function resolveImportsScope(query: string): ResolvedTarget[] {
    const pattern = query.length > 0 ? query : Process.enumerateModules()[0].path;
    return getModuleResolver()
        .enumerateMatches(`imports:${pattern}!*`)
        .map(moduleExportTargetFromMatch);
}

function resolveRelativeFunctionScope(query: string): ResolvedTarget[] {
    const { module, offset } = parseRelativeFunctionPattern(query);
    const base = Process.findModuleByName(module);
    if (base === null) {
        return [];
    }
    const address = base.base.add(offset);
    return [{
        scope: "relative-function",
        displayName: `${module}+0x${offset.toString(16)}`,
        detail: null,
        address: address.toString(),
        anchor: { type: "moduleOffset", name: module, offset },
    }];
}

function resolveAbsoluteInstructionScope(query: string): ResolvedTarget[] {
    const address = ptr(query);
    return [{
        scope: "absolute-instruction",
        displayName: address.toString(),
        detail: null,
        address: address.toString(),
        anchor: { type: "absolute", address: address.toString() },
    }];
}

function resolveObjcMethodScope(query: string): ResolvedTarget[] {
    return getObjcResolver().enumerateMatches(query).map(match => ({
        scope: "objc-method",
        displayName: match.name,
        detail: null,
        address: match.address.toString(),
        anchor: { type: "objcMethod", selector: match.name },
    }));
}

function resolveSwiftFuncScope(query: string): ResolvedTarget[] {
    return getSwiftResolver().enumerateMatches(`functions:${query}`).map(match => {
        const [moduleName, funcName] = splitScopedName(match.name);
        return {
            scope: "swift-func",
            displayName: funcName,
            detail: moduleName,
            address: match.address.toString(),
            anchor: { type: "swiftFunc", module: moduleName, function: funcName },
        };
    });
}

async function resolveJavaMethodScope(query: string): Promise<ResolvedTarget[]> {
    const Java = await loadJavaBridge();

    const targets: ResolvedTarget[] = [];
    Java.perform(() => {
        for (const group of Java.enumerateMethods(query)) {
            for (const klass of group.classes) {
                for (const methodName of klass.methods) {
                    const bareName = bareJavaMethodName(methodName);
                    targets.push({
                        scope: "java-method",
                        displayName: `${klass.name}.${bareName}`,
                        detail: klass.name,
                        address: "0x0",
                        anchor: { type: "javaMethod", className: klass.name, methodName: bareName },
                    });
                }
            }
        }
    });
    return targets;
}

export async function loadJavaBridge(): Promise<typeof _Java> {
    const cached = cachedJavaBridge;
    if (cached !== null) {
        return requireAvailable(cached);
    }

    let bridge: typeof _Java;
    try {
        const mod = await import("frida-java-bridge");
        bridge = (mod as any).default ?? mod;
    } catch (e) {
        throw new Error("The 'frida-java-bridge' package is required for Java tracing.");
    }

    cachedJavaBridge = bridge;
    return requireAvailable(bridge);
}

function requireAvailable(bridge: typeof _Java): typeof _Java {
    if (!bridge.available) {
        throw new Error("No Java runtime detected in this process.");
    }
    return bridge;
}

function bareJavaMethodName(name: string): string {
    const paren = name.indexOf("(");
    return (paren < 0) ? name : name.substring(0, paren);
}

function resolveDebugSymbolScope(query: string): ResolvedTarget[] {
    return DebugSymbol.findFunctionsMatching(query).map(address => {
        const symbol = DebugSymbol.fromAddress(address);
        const name = symbol.name ?? address.toString();
        return {
            scope: "debug-symbol",
            displayName: name,
            detail: symbol.moduleName ?? null,
            address: address.toString(),
            anchor: { type: "debugSymbol", name },
        };
    });
}

function moduleExportTargetFromMatch(match: ApiResolverMatch): ResolvedTarget {
    const [moduleName, symbolName] = splitScopedName(match.name);
    return {
        scope: "function",
        displayName: symbolName,
        detail: moduleName,
        address: match.address.toString(),
        anchor: { type: "moduleExport", name: moduleName, export: symbolName },
    };
}

function firstMatchAddress(matches: ApiResolverMatch[]): NativePointer | null {
    return matches.length > 0 ? matches[0].address : null;
}

function splitScopedName(name: string): [string, string] {
    const bang = name.indexOf("!");
    if (bang < 0) {
        return ["", name];
    }
    return [name.substring(0, bang), name.substring(bang + 1)];
}

function parseRelativeFunctionPattern(pattern: string): { module: string; offset: number } {
    const bang = pattern.indexOf("!");
    if (bang < 0) {
        throw new Error("Expected MODULE!OFFSET");
    }
    const module = pattern.substring(0, bang);
    const offset = parseInt(pattern.substring(bang + 1), 16);
    if (isNaN(offset)) {
        throw new Error("Invalid offset (expected hex)");
    }
    return { module, offset };
}

let cachedModuleResolver: ApiResolver | null = null;
let cachedObjcResolver: ApiResolver | null = null;
let cachedSwiftResolver: ApiResolver | null = null;
let cachedJavaBridge: typeof _Java | null = null;

function getModuleResolver(): ApiResolver {
    if (cachedModuleResolver === null) {
        cachedModuleResolver = new ApiResolver("module");
    }
    return cachedModuleResolver;
}

function getObjcResolver(): ApiResolver {
    if (cachedObjcResolver === null) {
        try {
            cachedObjcResolver = new ApiResolver("objc");
        } catch (e) {
            throw new Error("Objective-C runtime is not available in this process");
        }
    }
    return cachedObjcResolver;
}

function getSwiftResolver(): ApiResolver {
    if (cachedSwiftResolver === null) {
        try {
            cachedSwiftResolver = new ApiResolver("swift" as ApiResolverType);
        } catch (e) {
            throw new Error("Swift runtime is not available in this process");
        }
    }
    return cachedSwiftResolver;
}
