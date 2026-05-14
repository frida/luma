import Adw
import Gtk

@MainActor
enum UnsavedChangesDialog {
    static func present(
        anchor: WidgetProtocol,
        message: String,
        onSave: @escaping () -> Void,
        onDiscard: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        let dialog = Adw.AlertDialog(heading: "Unsaved Changes", body: message)
        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: "discard", label: "_Discard Changes")
        dialog.addResponse(id: "save", label: "_Save")
        dialog.setResponseAppearance(response: "discard", appearance: .destructive)
        dialog.setResponseAppearance(response: "save", appearance: .suggested)
        dialog.setDefault(response: "save")
        dialog.setClose(response: "cancel")
        dialog.onResponse { _, responseID in
            MainActor.assumeIsolated {
                switch responseID {
                case "save": onSave()
                case "discard": onDiscard()
                default: onCancel()
                }
            }
        }
        dialog.present(parent: WidgetRef(anchor))
    }
}
