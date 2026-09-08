import Foundation

public enum PackageAliasTypings {
    public static func declarations(for packages: [InstalledPackage]) -> [AmbientDeclarations] {
        let aliased = packages.compactMap { package -> (alias: String, module: String)? in
            guard let alias = package.globalAlias, !alias.isEmpty else { return nil }
            return (alias: alias, module: package.name)
        }
        guard !aliased.isEmpty else { return [] }

        var declarations = """
            type LumaPackageAlias<T> = T extends { default: infer D } ? D : T;

            declare global {

            """
        for (alias, moduleName) in aliased {
            declarations += """
                    const \(alias): LumaPackageAlias<typeof import("\(moduleName)")>;\n
                """
        }
        declarations += """
            }

            export {};
            """

        return [AmbientDeclarations(content: declarations, fileName: "package-aliases.d.ts")]
    }
}
