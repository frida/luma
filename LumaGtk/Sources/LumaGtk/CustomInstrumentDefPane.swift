import Adw
import CGtk
import Foundation
import GLibObject
import Gtk
import LumaCore

@MainActor
final class CustomInstrumentDefPane {
    let widget: Box
    private weak var engine: Engine?
    private(set) var def: CustomInstrumentDef
    private var draftSource: String
    private let sourceEditor: MonacoEditor
    private let saveButton: Button
    private let headerNameLabel: Label
    private let headerIconHost: Box

    init(engine: Engine, def: CustomInstrumentDef, sourceEditor: MonacoEditor) {
        self.engine = engine
        self.def = def
        self.draftSource = def.source
        self.sourceEditor = sourceEditor

        widget = Box(orientation: .vertical, spacing: 8)
        widget.hexpand = true
        widget.vexpand = true
        widget.marginTop = 12

        saveButton = Button(label: "Save")
        saveButton.add(cssClass: "suggested-action")
        saveButton.sensitive = false

        headerNameLabel = Label(str: def.name)
        headerNameLabel.halign = .start
        headerNameLabel.add(cssClass: "title-3")

        headerIconHost = Box(orientation: .horizontal, spacing: 0)
        headerIconHost.append(child: InstrumentIconView.makeImage(for: def.icon, pixelSize: 24))

        saveButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }

        layout()
    }

    func refresh(def: CustomInstrumentDef) {
        self.def = def
        headerNameLabel.label = def.name
        var child = headerIconHost.firstChild
        while let cur = child {
            child = cur.nextSibling
            headerIconHost.remove(child: cur)
        }
        headerIconHost.append(child: InstrumentIconView.makeImage(for: def.icon, pixelSize: 24))
        let packages = (try? engine?.store.fetchPackagesState().packages) ?? []
        sourceEditor.setProfile(EditorProfile.fridaCustomInstrument(packages: packages, def: def))
    }

    private func layout() {
        widget.append(child: header())
        widget.append(child: sourceEditorContainer())
    }

    private func header() -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.marginStart = 12
        row.marginEnd = 12
        row.append(child: headerIconHost)

        let titles = Box(orientation: .vertical, spacing: 0)
        titles.hexpand = true
        titles.append(child: headerNameLabel)
        let subtitle = Label(str: "Custom instrument")
        subtitle.halign = .start
        subtitle.add(cssClass: "caption")
        subtitle.add(cssClass: "dim-label")
        titles.append(child: subtitle)
        row.append(child: titles)

        row.append(child: saveButton)
        return row
    }

    private func sourceEditorContainer() -> Box {
        let container = Box(orientation: .vertical, spacing: 0)
        container.hexpand = true
        container.vexpand = true
        let packages = (try? engine?.store.fetchPackagesState().packages) ?? []
        sourceEditor.setProfile(EditorProfile.fridaCustomInstrument(packages: packages, def: def))
        sourceEditor.setText(draftSource)
        sourceEditor.installInto(container)
        sourceEditor.onTextChanged = { [weak self] text in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.draftSource = text
                self.saveButton.sensitive = self.isDirty()
            }
        }
        return container
    }

    private func commit() {
        guard let engine else { return }
        var updated = def
        updated.source = draftSource
        Task { @MainActor in
            await engine.updateCustomInstrument(updated)
            self.def = updated
            self.saveButton.sensitive = false
        }
    }

    private func isDirty() -> Bool {
        draftSource != def.source
    }
}
