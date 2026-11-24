import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class CustomInstrumentPackagesDialog {
    private let engine: Engine
    private var def: CustomInstrumentDef
    private let dialog: Adw.Dialog
    private let listBox = ListBox()
    private let emptyLabel = Label(str: "This instrument does not depend on any packages.")
    private let addButton = Button(label: "Add Package\u{2026}")

    init(engine: Engine, def: CustomInstrumentDef) {
        self.engine = engine
        self.def = def

        dialog = Adw.Dialog()
        dialog.set(title: "Packages")
        dialog.set(followsContentSize: true)

        layout()
        renderDependencies()
    }

    func present(parent: Gtk.Window) {
        dialog.own(self)
        dialog.present(parent: parent)
    }

    private func layout() {
        let content = Box(orientation: .vertical, spacing: 12)
        content.marginStart = 16
        content.marginEnd = 16
        content.marginTop = 16
        content.marginBottom = 16
        content.setSizeRequest(width: 520, height: -1)

        let intro = Label(str: "Packages this instrument imports. They are installed for this instrument alone and travel with it, ahead of the packages installed for the whole project.")
        intro.add(cssClass: "dim-label")
        intro.wrap = true
        intro.xalign = 0
        intro.maxWidthChars = 60
        content.append(child: intro)

        listBox.selectionMode = .none
        listBox.add(cssClass: "boxed-list")
        content.append(child: listBox)

        emptyLabel.add(cssClass: "dim-label")
        emptyLabel.halign = .start
        content.append(child: emptyLabel)

        let header = Adw.HeaderBar()
        addButton.add(cssClass: "suggested-action")
        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentPackagePicker(anchor: self.addButton)
            }
        }
        header.packEnd(child: addButton)

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: content)

        dialog.set(child: toolbarView)
    }

    private func renderDependencies() {
        while let child = listBox.firstChild {
            listBox.remove(child: child)
        }
        for name in def.dependencies.keys.sorted() {
            listBox.append(child: makeDependencyRow(name: name, versionSpec: def.dependencies[name]!))
        }
        listBox.visible = !def.dependencies.isEmpty
        emptyLabel.visible = def.dependencies.isEmpty
    }

    private func makeDependencyRow(name: String, versionSpec: String) -> ListBoxRow {
        let row = ListBoxRow()
        let box = Box(orientation: .horizontal, spacing: 8)
        box.marginStart = 12
        box.marginEnd = 8
        box.marginTop = 6
        box.marginBottom = 6

        let nameLabel = Label(str: name)
        nameLabel.halign = .start
        nameLabel.hexpand = true
        box.append(child: nameLabel)

        let versionLabel = Label(str: versionSpec)
        versionLabel.add(cssClass: "dim-label")
        box.append(child: versionLabel)

        let removeButton = Button()
        removeButton.set(iconName: "user-trash-symbolic")
        removeButton.tooltipText = "Remove Package"
        removeButton.add(cssClass: "flat")
        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.setDependency(name: name, versionSpec: nil) }
        }
        box.append(child: removeButton)

        row.set(child: box)
        return row
    }

    private func presentPackagePicker(anchor: Widget) {
        PackageSearchDialog.presentDependencyPicker(from: anchor, engine: engine) { [weak self] name, versionSpec in
            self?.setDependency(name: name, versionSpec: versionSpec)
        }
    }

    private func setDependency(name: String, versionSpec: String?) {
        def.dependencies[name] = versionSpec
        engine.updateCustomInstrument(def)
        renderDependencies()
    }
}
