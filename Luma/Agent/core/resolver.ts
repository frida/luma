export interface ResolvedApi {
    moduleName: string;
    symbolName: string;
    address: string;
}

export async function resolveApis(pattern: string): Promise<ResolvedApi[]> {
    const results: ResolvedApi[] = [];

    const resolver = new ApiResolver("module");
    for (const match of resolver.enumerateMatches(`exports:*!${pattern}`)) {
        const tokens = match.name.split("!");
        results.push({
            moduleName: tokens[0],
            symbolName: tokens[1],
            address: match.address.toString(),
        });
    }

    return results;
}
