import Foundation

public struct TypeScriptTypingFile: Sendable, Equatable {
    public let filePath: String
    public let content: String

    public init(filePath: String, content: String) {
        self.filePath = filePath
        self.content = content
    }
}

public enum TypeScriptTypings {
    public static let fridaGum: TypeScriptTypingFile? = {
        guard let url = Bundle.module.url(
            forResource: "frida-gum",
            withExtension: "d.ts",
            subdirectory: "Typings"
        ),
            let content = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return TypeScriptTypingFile(filePath: "@types/frida-gum/index.d.ts", content: content)
    }()
}
