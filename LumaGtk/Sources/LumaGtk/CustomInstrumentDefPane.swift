import Adw
import CGtk
import Foundation
import GLibObject
import Gtk
import LumaCore

@MainActor
final class CustomInstrumentDefPane {
    let widget: Box
    private(set) var def: CustomInstrumentDef
    private(set) var file: CustomInstrumentFile

    private weak var engine: Engine?
    private let sourceEditor: MonacoEditor
    private let saveBar: SaveBar
    private var draftContent: String

    init(engine: Engine, def: CustomInstrumentDef, file: CustomInstrumentFile, sourceEditor: MonacoEditor) {
        self.engine = engine
        self.def = def
        self.file = file
        self.draftContent = file.content
        self.sourceEditor = sourceEditor

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        var box: CustomInstrumentDefPane?
        saveBar = SaveBar(saveTooltip: "Save current file") {
            box?.commit()
        }

        layout()
        box = self
    }

    func refresh(def: CustomInstrumentDef, file: CustomInstrumentFile) {
        let pathChanged = self.file.path != file.path
        let storedContentChanged = self.file.content != file.content
        if pathChanged {
            flushDraftIfNeeded()
        }
        self.def = def
        self.file = file
        let packages = (try? engine?.store.fetchPackagesState().packages) ?? []
        sourceEditor.setProfile(currentProfile(def: def, file: file, packages: packages))
        if pathChanged || (storedContentChanged && !isDirty()) {
            sourceEditor.setText(file.content)
            draftContent = file.content
            saveBar.setDirty(false)
        }
    }

    private func currentProfile(
        def: CustomInstrumentDef,
        file: CustomInstrumentFile,
        packages: [LumaCore.InstalledPackage]
    ) -> EditorProfile {
        let files = engine?.customInstruments.files(forDefID: def.id) ?? []
        return EditorProfile.fridaCustomInstrument(
            packages: packages,
            def: def,
            files: files,
            activePath: CustomInstrumentFile.workspaceRelativePath(defID: def.id, path: file.path)
        )
    }

    private func layout() {
        let container = Box(orientation: .vertical, spacing: 0)
        container.hexpand = true
        container.vexpand = true
        let packages = (try? engine?.store.fetchPackagesState().packages) ?? []
        sourceEditor.setProfile(currentProfile(def: def, file: file, packages: packages))
        sourceEditor.setText(draftContent)
        sourceEditor.installInto(container)
        sourceEditor.onTextChanged = { [weak self] text in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.draftContent = text
                self.saveBar.setDirty(self.isDirty())
            }
        }

        let overlay = Overlay()
        overlay.hexpand = true
        overlay.vexpand = true
        overlay.set(child: container)
        overlay.addOverlay(widget: saveBar.widget)
        widget.append(child: overlay)
    }

    private func commit() {
        guard let engine else { return }
        let defID = def.id
        let path = file.path
        let content = draftContent
        Task { @MainActor in
            await engine.writeCustomInstrumentFile(defID: defID, path: path, content: content)
            self.saveBar.setDirty(false)
        }
    }

    func flushDraftIfNeeded() {
        guard isDirty(), let engine else { return }
        let defID = def.id
        let path = file.path
        let content = draftContent
        Task { @MainActor in
            await engine.writeCustomInstrumentFile(defID: defID, path: path, content: content)
        }
    }

    private func isDirty() -> Bool {
        draftContent != file.content
    }
}
