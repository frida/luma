import Adw
import CLuma
import Foundation
import Gtk
import LumaCore

@MainActor
final class CustomInstrumentRenameDialog {
    private let engine: Engine
    private let def: CustomInstrumentDef
    private let nameEntry: Entry
    private let dialog: Adw.AlertDialog
    private let parentWindow: Gtk.Window
    private let conceptGrid = InstrumentIconConceptGrid()
    private let bitmapPreview: Box
    private var draftIcon: InstrumentIcon

    init(engine: Engine, def: CustomInstrumentDef, parentWindow: Gtk.Window) {
        self.engine = engine
        self.def = def
        self.parentWindow = parentWindow
        self.draftIcon = def.icon

        nameEntry = Entry()
        nameEntry.text = def.name
        nameEntry.hexpand = true
        nameEntry.onMap { mapped in
            _ = mapped.grabFocus()
        }

        bitmapPreview = Box(orientation: .horizontal, spacing: 0)

        dialog = Adw.AlertDialog(heading: "Rename & Icon", body: nil)
        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: "save", label: "_Save")
        dialog.setResponseAppearance(response: "save", appearance: .suggested)
        dialog.setDefault(response: "save")
        dialog.setClose(response: "cancel")
        dialog.setExtra(child: layoutContent())

        nameEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSaveEnabled() }
        }
        conceptGrid.onChoose = { [weak self] id in
            self?.applyGridSelection(id)
        }
        dialog.onResponse { [weak self] _, responseID in
            MainActor.assumeIsolated {
                guard let self else { return }
                if responseID == "save" { self.commit() }
            }
        }
        applyDraftToVisuals()
    }

    func present() {
        dialog.own(self)
        dialog.present(parent: parentWindow)
    }

    private var proposedName: String {
        (nameEntry.text ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func refreshSaveEnabled() {
        dialog.setResponseEnabled(response: "save", enabled: !proposedName.isEmpty)
    }

    private func layoutContent() -> Box {
        let column = Box(orientation: .vertical, spacing: 12)
        column.append(child: nameRow())
        column.append(child: iconSectionLabel())
        column.append(child: conceptGrid.widget)
        column.append(child: customRow())
        return column
    }

    private func nameRow() -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        let label = Label(str: "Name")
        label.halign = .start
        label.setSizeRequest(width: 80, height: -1)
        row.append(child: label)
        row.append(child: nameEntry)
        return row
    }

    private func iconSectionLabel() -> Label {
        let label = Label(str: "Icon")
        label.halign = .start
        label.add(cssClass: "caption-heading")
        return label
    }

    private func customRow() -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.append(child: bitmapPreview)
        let chooseButton = Button(label: "Choose File\u{2026}")
        chooseButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.openFilePicker() }
        }
        row.append(child: chooseButton)
        return row
    }

    private func openFilePicker() {
        guard let parentPtr = parentWindow.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        "Choose icon image".withCString { title in
            luma_file_dialog_open(parentPtr, title, customInstrumentIconPathThunk, context)
        }
    }

    fileprivate func handlePickedFile(_ path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let normalized = normalizeIconImage(data)
        else { return }
        draftIcon = .pixels(normalized)
        applyDraftToVisuals()
    }

    private func applyDraftToVisuals() {
        if case .symbolic(let id) = draftIcon {
            conceptGrid.show(id)
        } else {
            conceptGrid.show(nil)
        }
        renderBitmapPreview()
    }

    private func applyGridSelection(_ id: String) {
        if case .symbolic(let current) = draftIcon, current == id { return }
        draftIcon = .symbolic(id)
        renderBitmapPreview()
    }

    private func renderBitmapPreview() {
        while let child = bitmapPreview.firstChild {
            bitmapPreview.remove(child: child)
        }
        if case .pixels = draftIcon {
            bitmapPreview.append(child: InstrumentIconView.makeImage(for: draftIcon, pixelSize: 32))
        }
    }

    private func commit() {
        let name = proposedName
        let icon = draftIcon
        engine.updateCustomInstrument(def.id) {
            $0.name = name
            $0.icon = icon
        }
    }

}

private func normalizeIconImage(_ data: Data) -> Data? {
    var outBytes: UnsafeMutablePointer<UInt8>? = nil
    var outSize: Int = 0
    let ok = data.withUnsafeBytes { buffer -> Bool in
        guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return false }
        return luma_image_normalize_to_png(base, buffer.count, 128, &outBytes, &outSize, nil, nil)
    }
    guard ok, let outBytes, outSize > 0 else { return nil }
    defer { free(outBytes) }
    return Data(bytes: outBytes, count: outSize)
}

private let customInstrumentIconPathThunk: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let userData else { return }
    let dialog = Unmanaged<CustomInstrumentRenameDialog>.fromOpaque(userData).takeRetainedValue()
    guard let pathPtr else { return }
    let path = String(cString: pathPtr)
    Task { @MainActor in
        dialog.handlePickedFile(path)
    }
}
