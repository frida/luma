import Adw
import CLuma
import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class PatternsListPane {
    let widget: Box

    private let engine: Engine
    private let window: Gtk.Window
    private let onSelect: (String) -> Void
    private let onError: (String) -> Void
    private let body: Box

    init(engine: Engine, window: Gtk.Window, onSelect: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.engine = engine
        self.window = window
        self.onSelect = onSelect
        self.onError = onError

        widget = Box(orientation: .vertical, spacing: 12)
        widget.hexpand = true
        widget.vexpand = true
        widget.marginStart = 18
        widget.marginEnd = 18
        widget.marginTop = 18
        widget.marginBottom = 18

        body = Box(orientation: .vertical, spacing: 0)
        body.hexpand = true
        body.vexpand = true

        widget.append(child: makeHeader())
        widget.append(child: body)
        render()
        observeSources()
    }

    private func makeHeader() -> Box {
        let header = Box(orientation: .horizontal, spacing: 8)

        let title = Label(str: "Patterns")
        title.add(cssClass: "title-2")
        title.halign = .start
        title.hexpand = true
        header.append(child: title)

        let importButton = Button(label: "Import…")
        importButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.presentImport() }
        }
        header.append(child: importButton)

        header.append(child: makeNewButton())
        return header
    }

    private func presentImport() {
        let parentPtr = UnsafeMutableRawPointer(window.window_ptr!)
        let context = Unmanaged.passRetained(self).toOpaque()
        "Import Pattern".withCString { title in
            luma_file_dialog_open(parentPtr, title, patternImportThunk, context)
        }
    }

    fileprivate func importFile(atPath path: String?) {
        guard let path else { return }
        do {
            onSelect(try engine.patterns.importFile(at: URL(fileURLWithPath: path)).id)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func makeNewButton() -> Button {
        let button = Button(label: "New")
        button.add(cssClass: "suggested-action")
        button.onClicked { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                guard let self, let button else { return }
                ContextMenu.present([
                    [
                        .init("New Pattern") { [weak self] in self?.presentCreate(.pattern) },
                        .init("New Library") { [weak self] in self?.presentCreate(.library) },
                    ]
                ], at: button, x: 0, y: Double(button.height))
            }
        }
        return button
    }

    private func presentCreate(_ kind: PatternSource.Kind) {
        let entry = Entry()
        entry.hexpand = true
        entry.activatesDefault = true
        let dialog = Adw.AlertDialog(heading: "New \(kind.title)", body: nil)
        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: "create", label: "C_reate")
        dialog.setResponseAppearance(response: "create", appearance: .suggested)
        dialog.setDefault(response: "create")
        dialog.setClose(response: "cancel")
        dialog.setExtra(child: entry)
        dialog.onResponse { [weak self] _, responseID in
            MainActor.assumeIsolated {
                guard let self, responseID == "create" else { return }
                self.create(kind, named: entry.text)
            }
        }
        dialog.present(parent: window)
    }

    private func create(_ kind: PatternSource.Kind, named name: String) {
        do {
            onSelect(try engine.patterns.create(named: name, kind: kind).id)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func render() {
        while let child = body.firstChild {
            body.remove(child: child)
        }
        let sources = engine.patterns.sources
        body.append(child: sources.isEmpty ? makeEmptyState() : makeList(sources))
    }

    private func makeEmptyState() -> Widget {
        let page = Adw.StatusPage()
        page.iconName = "view-grid-symbolic"
        page.title = "No patterns yet"
        page.description =
            "Pattern files describe structs to decode memory against. Libraries hold definitions shared between them. Packages from npm bring ready-made ones for PE, Mach-O and ELF."
        page.vexpand = true
        let actions = Box(orientation: .horizontal, spacing: 12)
        actions.halign = .center
        let addPackage = Button(label: "Add Pattern Package…")
        addPackage.add(cssClass: "suggested-action")
        addPackage.add(cssClass: "pill")
        addPackage.onClicked { [weak self, weak addPackage] _ in
            MainActor.assumeIsolated {
                guard let self, let addPackage else { return }
                PackageSearchDialog.present(from: addPackage, engine: self.engine, category: .pattern) { [weak self] installed in
                    self?.onSelect("package:" + installed.name)
                }
            }
        }
        actions.append(child: addPackage)
        let newButton = makeNewButton()
        newButton.remove(cssClass: "suggested-action")
        newButton.add(cssClass: "pill")
        actions.append(child: newButton)
        page.set(child: actions)
        return page
    }

    private func makeList(_ sources: [PatternSource]) -> Widget {
        let list = ListBox()
        list.selectionMode = .none
        list.add(cssClass: "boxed-list")
        list.valign = .start
        for source in sources {
            list.append(child: makeRow(source))
        }
        list.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                self?.onSelect(sources[Int(row.index)].id)
            }
        }
        let scroller = ScrolledWindow()
        scroller.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroller.vexpand = true
        scroller.set(child: list)
        return scroller
    }

    private func makeRow(_ source: PatternSource) -> ListBoxRow {
        let box = Box(orientation: .horizontal, spacing: 10)
        box.marginStart = 12
        box.marginEnd = 12
        box.marginTop = 8
        box.marginBottom = 8

        let icon = Gtk.Image(iconName: source.iconName)
        icon.pixelSize = 16
        icon.add(cssClass: "dim-label")
        box.append(child: icon)

        let text = Box(orientation: .vertical, spacing: 2)
        text.hexpand = true
        let name = Label(str: source.name)
        name.add(cssClass: "heading")
        name.halign = .start
        text.append(child: name)
        let path = Label(str: source.originDescription)
        path.add(cssClass: "caption")
        path.add(cssClass: "dim-label")
        path.halign = .start
        text.append(child: path)
        box.append(child: text)

        let kind = Label(str: source.kind.title)
        kind.add(cssClass: "caption")
        kind.add(cssClass: "dim-label")
        box.append(child: kind)

        let row = ListBoxRow()
        row.activatable = true
        row.set(child: box)
        return row
    }

    private func observeSources() {
        withObservationTracking {
            _ = engine.patterns.sources
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.render()
                self.observeSources()
            }
        }
    }
}

private let patternImportThunk: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { pathPtr, userData in
    let path = pathPtr.map { String(cString: $0) }
    let pane = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        Unmanaged<PatternsListPane>.fromOpaque(UnsafeMutableRawPointer(bitPattern: pane)!).takeRetainedValue().importFile(atPath: path)
    }
}
