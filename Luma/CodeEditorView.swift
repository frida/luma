import LumaCore
import SwiftUI
import SwiftyMonaco

struct CodeEditorView: View {
    @Binding var text: String
    let profile: MonacoEditorProfile
    var introspector: MonacoIntrospector? = nil
    @ObservedObject var workspace: Workspace

    var body: some View {
        let packages: [LumaCore.InstalledPackage] = []
        let injectedProfile = profileWithGlobalAliasTypings(from: profile, packages: packages)

        var editor = SwiftyMonaco(text: $text, profile: injectedProfile)
            .fsSnapshot(workspace.monacoFSSnapshot)

        if let introspector {
            editor = editor.introspector(introspector)
        }

        return editor.task {
            await workspace.rebuildMonacoFSSnapshotIfNeeded()
        }
    }

    private func profileWithGlobalAliasTypings(
        from base: MonacoEditorProfile,
        packages: [InstalledPackage]
    ) -> MonacoEditorProfile {
        guard let generated = MonacoPackageAliasTypings.makeLib(packages: packages) else {
            return base
        }
        let lib = MonacoExtraLib(generated.content, filePath: generated.filePath)
        var copy = base
        copy.tsExtraLibs.append(lib)
        copy.jsExtraLibs.append(lib)
        return copy
    }
}
