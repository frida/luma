import LumaCore
import SwiftyMonaco

// All translation between LumaCore's editor model and SwiftyMonaco's
// concrete editor types lives here so the rest of the macOS host can
// stay free of `MonacoFSSnapshot` / `MonacoEditorProfile` ambiguity.

extension MonacoExtraLib {
    init(from lib: LumaCore.EditorExtraLib) {
        self.init(lib.content, filePath: lib.filePath)
    }
}

extension TypeScriptCompilerOptions {
    init(from options: LumaCore.EditorCompilerOptions) {
        self.init(
            target: options.target.flatMap { TypeScriptScriptTarget(rawValue: $0.rawValue) },
            lib: options.lib?.compactMap { TypeScriptLib(rawValue: $0) },
            module: options.module.flatMap { TypeScriptModuleKind(rawValue: $0.rawValue) },
            moduleResolution: options.moduleResolution.flatMap {
                TypeScriptModuleResolutionKind(rawValue: $0.rawValue)
            },
            typeRoots: options.typeRoots,
            strict: options.strict
        )
    }
}

extension MonacoFSSnapshot {
    init(from snapshot: LumaCore.EditorFSSnapshot) {
        self.init(
            version: snapshot.version,
            files: snapshot.files.map { MonacoFSSnapshotFile(path: $0.path, text: $0.text) }
        )
    }
}

extension MonacoEditorProfile {
    init(from profile: LumaCore.EditorProfile) {
        self.init(
            syntax: .monaco(languageId: profile.languageId),
            tsCompilerOptions: profile.tsCompilerOptions.isEmpty
                ? nil : TypeScriptCompilerOptions(from: profile.tsCompilerOptions),
            tsExtraLibs: profile.tsExtraLibs.map { MonacoExtraLib(from: $0) },
            jsCompilerOptions: profile.jsCompilerOptions.isEmpty
                ? nil : TypeScriptCompilerOptions(from: profile.jsCompilerOptions),
            jsExtraLibs: profile.jsExtraLibs.map { MonacoExtraLib(from: $0) },
            minimap: profile.minimap,
            fontSize: profile.fontSize,
            theme: profile.theme == .dark ? .dark : .light
        )
    }
}
