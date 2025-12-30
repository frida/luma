import SwiftData
import SwiftUI
import SwiftyMonaco

struct CodeEditorView: View {
    @Binding var text: String
    let profile: MonacoEditorProfile
    var introspector: MonacoIntrospector? = nil
    @ObservedObject var workspace: Workspace

    @Query private var projectPackageStates: [ProjectPackagesState]

    var body: some View {
        let packages = projectPackageStates.flatMap { $0.packages }
        let injectedProfile = profileWithGlobalAliasTypings(from: profile, packages: packages)

        var editor = SwiftyMonaco(text: $text, profile: injectedProfile)
            .fsSnapshot(workspace.monacoFSSnapshot)

        if let introspector {
            editor = editor.introspector(introspector)
        }

        return editor.task {
            _ = try? await workspace.ensureCompilerWorkspaceReady()
        }
    }

    private func profileWithGlobalAliasTypings(
        from base: MonacoEditorProfile,
        packages: [InstalledPackage]
    ) -> MonacoEditorProfile {
        let aliased = packages.compactMap { pkg -> (alias: String, module: String)? in
            guard let alias = pkg.globalAlias, !alias.isEmpty else { return nil }
            return (alias: alias, module: pkg.name)
        }

        guard !aliased.isEmpty else { return base }

        var dts = """
            type LumaPackageAlias<T> = T extends { default: infer D } ? D : T;

            declare global {

            """

        for (alias, moduleName) in aliased {
            dts += """
                    const \(alias): LumaPackageAlias<typeof import("\(moduleName)")>;\n
                """
        }

        dts += """
            }

            export {};
            """

        let lib = MonacoExtraLib(dts, filePath: "file:///workspace/luma-package-aliases.d.ts")

        var copy = base
        copy.tsExtraLibs.append(lib)
        copy.jsExtraLibs.append(lib)
        return copy
    }
}
