import LumaCore
import SwiftyMonaco

enum CodeShareEditorProfile {
    static let javascript: MonacoEditorProfile = MonacoEditorProfileBuilder()
        .syntax(.monaco(languageId: "javascript"))
        .javascriptCompilerOptions(TypeScriptEnvironment.defaultCompilerOptions)
        .javascriptExtraLibs([
            TypeScriptEnvironment.gumTypeLib
        ])
        .build()
}
