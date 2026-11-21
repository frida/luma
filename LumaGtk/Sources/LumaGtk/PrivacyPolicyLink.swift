import Foundation
import Gtk
import LumaCore

enum PrivacyPolicyLink {
    static let markup = "<a href=\"\(BackendConfig.privacyPolicyURL.absoluteString)\">Privacy Policy</a>"

    static func markup(following text: String) -> String {
        "\(StyledTextPango.escape(text)) \(markup)"
    }

    static func open(from anchor: some Gtk.WidgetProtocol) {
        let launcher = UriLauncher(uri: BackendConfig.privacyPolicyURL.absoluteString)
        let parentWindow = anchor.root?.ptr.map { Gtk.WindowRef(raw: $0) }
        launcher.launch(parent: parentWindow, cancellable: nil, callback: nil, userData: nil)
    }
}
