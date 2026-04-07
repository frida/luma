import Foundation
import LumaCore
import SwiftyMonaco

public enum TypeScriptEnvironment {
    public static let defaultCompilerOptions: TypeScriptCompilerOptions = .init(
        target: .es2022,
        lib: [.es2022],
        module: .node16,
        strict: true
    )

    public static let gumTypeLib: MonacoExtraLib = {
        guard let typing = LumaCore.TypeScriptTypings.fridaGum else {
            fatalError("frida-gum.d.ts is missing from LumaCore resources. This is required.")
        }
        return MonacoExtraLib(typing.content, filePath: typing.filePath)
    }()
}
