import Adw
import Gtk

@MainActor
enum LocalChangesConfirmation {
    static func present(
        heading: String,
        body: String,
        discardLabel: String,
        over parent: some Gtk.WidgetProtocol,
        onDiscard: @escaping () -> Void
    ) {
        let alert = Adw.AlertDialog(heading: heading, body: body)
        alert.addResponse(id: "cancel", label: "_Cancel")
        alert.addResponse(id: "discard", label: discardLabel)
        alert.setResponseAppearance(response: "discard", appearance: .destructive)
        alert.setDefault(response: "cancel")
        alert.setClose(response: "cancel")
        alert.onResponse { _, responseID in
            MainActor.assumeIsolated {
                guard responseID == "discard" else { return }
                onDiscard()
            }
        }
        alert.present(parent: parent)
    }
}
