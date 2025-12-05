import Foundation
import SwiftyMonaco

public enum TypeScriptEnvironment {
    public static let defaultCompilerOptions: TypeScriptCompilerOptions = .init(
        target: .es2022,
        lib: [.es2022],
        module: .node16,
        strict: true
    )

    public static let gumTypeLib: MonacoExtraLib = {
        guard let url = Bundle.main.url(forResource: "frida-gum", withExtension: "d.ts") else {
            fatalError("frida-gum.d.ts is missing from the app bundle. This is required.")
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Unable to read frida-gum.d.ts from app bundle.")
        }

        return MonacoExtraLib(content, filePath: "@types/frida-gum/index.d.ts")
    }()
}
