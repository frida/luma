import Adw
import Foundation
import Gtk

@MainActor
enum RejectionDialog {
    static func present(heading: String, body: String, parent: Widget, onReject: @escaping (String?) -> Void) {
        let dialog = Adw.AlertDialog(heading: heading, body: body)

        let extra = Box(orientation: .vertical, spacing: 8)
        extra.marginStart = 12
        extra.marginEnd = 12
        extra.marginTop = 8
        extra.marginBottom = 8
        let entry = Entry()
        entry.placeholderText = "Reason (optional)"
        entry.hexpand = true
        extra.append(child: entry)
        dialog.extraChild = WidgetRef(extra)

        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: "reject", label: "Reject")
        dialog.setResponseAppearance(response: "reject", appearance: .destructive)
        dialog.setDefault(response: "cancel")
        dialog.setClose(response: "cancel")

        dialog.onResponse { _, responseID in
            MainActor.assumeIsolated {
                guard responseID == "reject" else { return }
                let reason = (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                onReject(reason.isEmpty ? nil : reason)
            }
        }
        dialog.present(parent: parent)
    }
}
