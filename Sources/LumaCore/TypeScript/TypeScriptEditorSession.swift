import Foundation

@MainActor
public final class TypeScriptEditorSession {
    public let project: TypeScriptProject
    public let document: TypeScriptDocument

    private init(project: TypeScriptProject, document: TypeScriptDocument) {
        self.project = project
        self.document = document
    }

    public static func open(engine: Engine, profile: EditorProfile, text: String) async throws -> TypeScriptEditorSession {
        let project = try await engine.typeScriptProject(for: profile)
        for file in profile.projectFiles where file.path != profile.activePath {
            _ = project.openDocument(path: file.path, text: file.text, languageId: file.languageId ?? profile.languageId)
        }
        let document = project.openDocument(
            path: profile.activePath ?? scratchPath(for: profile.languageId),
            text: text,
            languageId: profile.languageId
        )
        return TypeScriptEditorSession(project: project, document: document)
    }

    public static func isSameProject(_ a: EditorProfile, _ b: EditorProfile) -> Bool {
        a.languageId == b.languageId
            && a.activePath == b.activePath
            && a.projectFiles == b.projectFiles
            && a.ambientDeclarations == b.ambientDeclarations
    }

    public func close() {
        document.close()
    }

    private static func scratchPath(for languageId: String) -> String {
        "Editor/\(UUID().uuidString)." + (languageId == "javascript" ? "js" : "ts")
    }
}
