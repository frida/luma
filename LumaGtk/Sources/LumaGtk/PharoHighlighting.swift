import Foundation
import GtkSource

/// The Smalltalk language and theme the Pharo editors read by, set up once and
/// shared between the playground and the notebook rather than each pane wiring
/// its own manager.
@MainActor
enum PharoHighlighting {
    private static let languageManager = GtkSource.LanguageManager()
    private static let schemeManager = GtkSource.StyleSchemeManager()
    private static var resolved = false
    private static var language: GtkSource.LanguageRef?
    private static var scheme: GtkSource.StyleSchemeRef?

    static func apply(to buffer: GtkSource.Buffer) {
        resolve()
        buffer.language = language
        buffer.styleScheme = scheme
        buffer.highlightSyntax = true
    }

    private static func resolve() {
        guard !resolved else { return }
        resolved = true
        if let specs = Bundle.module.url(forResource: "smalltalk", withExtension: "lang", subdirectory: "pharo")?
            .deletingLastPathComponent().path {
            languageManager.appendSearchPath(path: specs)
            schemeManager.appendSearchPath(path: specs)
        }
        language = languageManager.getLanguage(id: "smalltalk")
        scheme = schemeManager.getScheme(schemeId: "luma")
    }
}
