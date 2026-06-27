import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
enum CustomInstrumentFileDialogs {
    static func presentAdd(
        engine: Engine,
        def: CustomInstrumentDef,
        parent: Gtk.Window,
        onCreated: @escaping (String) -> Void
    ) {
        let defID = def.id
        CustomInstrumentPathDialog(
            heading: "Add File",
            body: "Relative path inside this instrument. Subdirectories allowed.",
            actionID: "add",
            actionLabel: "_Add",
            initialText: "",
            placeholderText: "path/to/file.ts",
            isValid: { input in
                guard !input.isEmpty else { return false }
                return engine.customInstruments.file(defID: defID, path: input) == nil
            },
            onCommit: { input in
                Task { @MainActor in
                    do {
                        let path = try engine.writeCustomInstrumentFile(defID: defID, path: input, content: "")
                        onCreated(path)
                    } catch {
                        presentError(error, parent: parent)
                    }
                }
            }
        ).present(parent: parent)
    }

    static func presentRename(
        engine: Engine,
        def: CustomInstrumentDef,
        file: CustomInstrumentFile,
        parent: Gtk.Window,
        onRenamed: @escaping (String) -> Void
    ) {
        let defID = def.id
        let oldPath = file.path
        let body = file.path == def.entrypoint
            ? "Renaming the entrypoint updates the entrypoint automatically."
            : "Relative path inside this instrument."
        CustomInstrumentPathDialog(
            heading: "Rename File",
            body: body,
            actionID: "rename",
            actionLabel: "_Rename",
            initialText: file.path,
            placeholderText: nil,
            isValid: { input in
                guard !input.isEmpty, input != oldPath else { return false }
                return engine.customInstruments.file(defID: defID, path: input) == nil
            },
            onCommit: { input in
                Task { @MainActor in
                    do {
                        let renamedPath = try engine.renameCustomInstrumentFile(defID: defID, from: oldPath, to: input)
                        onRenamed(renamedPath)
                    } catch {
                        presentError(error, parent: parent)
                    }
                }
            }
        ).present(parent: parent)
    }

    private static func presentError(_ error: Error, parent: Gtk.Window) {
        let dialog = Adw.AlertDialog(heading: "Custom instrument error", body: error.localizedDescription)
        dialog.addResponse(id: "ok", label: "OK")
        dialog.setDefault(response: "ok")
        dialog.setClose(response: "ok")
        dialog.present(parent: parent)
    }
}

@MainActor
private final class CustomInstrumentPathDialog {
    private let dialog: Adw.AlertDialog
    private let pathEntry: Entry
    private let actionID: String
    private let isValid: (String) -> Bool
    private let onCommit: (String) -> Void

    init(
        heading: String,
        body: String,
        actionID: String,
        actionLabel: String,
        initialText: String,
        placeholderText: String?,
        isValid: @escaping (String) -> Bool,
        onCommit: @escaping (String) -> Void
    ) {
        self.actionID = actionID
        self.isValid = isValid
        self.onCommit = onCommit

        pathEntry = Entry()
        pathEntry.text = initialText
        pathEntry.hexpand = true
        pathEntry.activatesDefault = true
        if let placeholderText {
            pathEntry.placeholderText = placeholderText
        }

        dialog = Adw.AlertDialog(heading: heading, body: body)
        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: actionID, label: actionLabel)
        dialog.setResponseAppearance(response: actionID, appearance: .suggested)
        dialog.setDefault(response: actionID)
        dialog.setClose(response: "cancel")
        dialog.setExtra(child: pathEntry)
        dialog.setResponseEnabled(response: actionID, enabled: isValid(normalizedInput))

        pathEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEnabled() }
        }

        dialog.onResponse { [weak self] _, responseID in
            MainActor.assumeIsolated {
                guard let self else { return }
                if responseID == self.actionID {
                    self.onCommit(self.normalizedInput)
                }
                Self.retained.removeValue(forKey: ObjectIdentifier(self.dialog))
            }
        }
    }

    func present(parent: Gtk.Window) {
        Self.retained[ObjectIdentifier(dialog)] = self
        dialog.present(parent: parent)
        Task { @MainActor in _ = pathEntry.grabFocus() }
    }

    private func refreshEnabled() {
        dialog.setResponseEnabled(response: actionID, enabled: isValid(normalizedInput))
    }

    private var normalizedInput: String {
        (pathEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var retained: [ObjectIdentifier: CustomInstrumentPathDialog] = [:]
}
