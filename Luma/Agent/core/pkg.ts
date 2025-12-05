type PackageBundle = {
    name: string;
    bundle: string;
    globalAlias?: string;
};

export async function loadPackages(bundles: PackageBundle[]): Promise<void> {
    for (const { name, bundle, globalAlias } of bundles) {
        const ns = await Script.load(name, bundle);

        if (globalAlias !== undefined) {
            (globalThis as any)[globalAlias] = ns.default ?? ns;
        }
    }
}
