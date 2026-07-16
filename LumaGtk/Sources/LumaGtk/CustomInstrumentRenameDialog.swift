import Adw
import CLuma
import Foundation
import Gtk
import LumaCore

@MainActor
final class CustomInstrumentRenameDialog {
    private let engine: Engine
    private var def: CustomInstrumentDef
    private let nameEntry: Entry
    private let dialog: Adw.AlertDialog
    private let parentWindow: Gtk.Window
    private let conceptGrid: FlowBox
    private let conceptChildren: [(InstrumentIconConcept, FlowBoxChild)]
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

        bitmapPreview = Box(orientation: .horizontal, spacing: 0)

        conceptGrid = FlowBox()
        conceptGrid.selectionMode = .single
        conceptGrid.maxChildrenPerLine = 8
        conceptGrid.minChildrenPerLine = 8
        conceptGrid.homogeneous = true
        conceptGrid.columnSpacing = 4
        conceptGrid.rowSpacing = 4

        var children: [(InstrumentIconConcept, FlowBoxChild)] = []
        for concept in InstrumentIconCatalog.userPickable {
            let child = FlowBoxChild()
            child.tooltipText = concept.displayName
            child.set(child: InstrumentIconView.makeImage(for: .symbolic(concept.id), pixelSize: 20))
            conceptGrid.append(child: child)
            children.append((concept, child))
        }
        conceptChildren = children

        dialog = Adw.AlertDialog(heading: "Rename Instrument", body: nil)
        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: "save", label: "_Save")
        dialog.setResponseAppearance(response: "save", appearance: .suggested)
        dialog.setDefault(response: "save")
        dialog.setClose(response: "cancel")
        dialog.setExtra(child: layoutContent())

        conceptGrid.onSelectedChildrenChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.applyGridSelection() }
        }
        dialog.onResponse { [weak self] _, responseID in
            MainActor.assumeIsolated {
                guard let self else { return }
                if responseID == "save" { self.commit() }
                Self.retained.removeValue(forKey: ObjectIdentifier(self.dialog))
            }
        }
        applyDraftToVisuals()
    }

    func present() {
        Self.retained[ObjectIdentifier(dialog)] = self
        dialog.present(parent: parentWindow)
        Task { @MainActor in _ = nameEntry.grabFocus() }
    }

    private func layoutContent() -> Box {
        let column = Box(orientation: .vertical, spacing: 12)
        column.append(child: nameRow())
        column.append(child: iconSectionLabel())
        column.append(child: conceptGrid)
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
        if case .symbolic(let id) = draftIcon,
            let child = conceptChildren.first(where: { $0.0.id == id })?.1
        {
            conceptGrid.select(child: child)
        } else {
            conceptGrid.unselectAll()
        }
        renderBitmapPreview()
    }

    private func applyGridSelection() {
        guard let match = conceptChildren.first(where: { $0.1.isSelected })?.0 else { return }
        if case .symbolic(let id) = draftIcon, id == match.id { return }
        draftIcon = .symbolic(match.id)
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
        let proposedName = (nameEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        var updated = def
        updated.name = proposedName.isEmpty ? def.name : proposedName
        updated.icon = draftIcon
        let engine = self.engine
        Task { @MainActor in
            engine.updateCustomInstrument(updated)
        }
    }

    private static var retained: [ObjectIdentifier: CustomInstrumentRenameDialog] = [:]
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
