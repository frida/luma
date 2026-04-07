import Foundation
import Gtk
import LumaCore

@MainActor
final class AddInstrumentDialog {
    typealias OnPick = (LumaCore.InstrumentDescriptor) -> Void

    private let window: Window
    private let descriptors: [LumaCore.InstrumentDescriptor]
    private let onPick: OnPick

    private let listBox: ListBox
    private let addButton: Button

    private var selectedIndex: Int?

    init(parent: Window, descriptors: [LumaCore.InstrumentDescriptor], onPick: @escaping OnPick) {
        self.descriptors = descriptors
        self.onPick = onPick

        window = Window()
        window.title = "Add Instrument"
        window.setDefaultSize(width: 480, height: 360)
        window.modal = true
        window.setTransientFor(parent: parent)
        window.destroyWithParent = true

        listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")

        addButton = Button(label: "Add")
        addButton.add(cssClass: "suggested-action")
        addButton.sensitive = false

        let header = HeaderBar()
        let cancelButton = Button(label: "Cancel")
        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        header.packStart(child: cancelButton)
        header.packEnd(child: addButton)
        window.set(titlebar: WidgetRef(header))

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: listBox)
        window.set(child: scroll)

        for descriptor in descriptors {
            let row = ListBoxRow()
            let label = Label(str: descriptor.displayName)
            label.halign = .start
            label.marginStart = 12
            label.marginEnd = 12
            label.marginTop = 8
            label.marginBottom = 8
            row.set(child: label)
            listBox.append(child: row)
        }

        listBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let row {
                    self.selectedIndex = Int(row.index)
                    self.addButton.sensitive = true
                } else {
                    self.selectedIndex = nil
                    self.addButton.sensitive = false
                }
            }
        }

        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
    }

    func present() {
        window.present()
    }

    private func close() {
        window.destroy()
    }

    private func commit() {
        guard let index = selectedIndex, index < descriptors.count else { return }
        onPick(descriptors[index])
        close()
    }
}
