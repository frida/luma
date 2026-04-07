import Foundation
import Gtk
import LumaCore

@MainActor
final class AddInstrumentDialog {
    typealias OnAdded = (LumaCore.InstrumentInstance) -> Void

    private let window: Window
    private let descriptors: [LumaCore.InstrumentDescriptor]
    private let onAdded: OnAdded?
    private let engine: Engine
    private let sessionID: UUID

    private let listBox: ListBox
    private let addButton: Button
    private let detailContainer: Box

    private var selectedIndex: Int?

    init(
        parent: Window,
        engine: Engine,
        sessionID: UUID,
        descriptors: [LumaCore.InstrumentDescriptor],
        onAdded: OnAdded? = nil
    ) {
        self.descriptors = descriptors
        self.onAdded = onAdded
        self.engine = engine
        self.sessionID = sessionID

        window = Window()
        window.title = "Add Instrument"
        window.setDefaultSize(width: 900, height: 600)
        window.modal = true
        window.setTransientFor(parent: parent)
        window.destroyWithParent = true

        listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")

        addButton = Button(label: "Add")
        addButton.add(cssClass: "suggested-action")
        addButton.sensitive = false

        detailContainer = Box(orientation: .vertical, spacing: 0)
        detailContainer.hexpand = true
        detailContainer.vexpand = true

        let header = HeaderBar()
        let cancelButton = Button(label: "Cancel")
        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        header.packStart(child: cancelButton)
        let browseButton = Button(label: "Browse CodeShare\u{2026}")
        browseButton.onClicked { [weak self, weak browseButton] _ in
            MainActor.assumeIsolated {
                guard let self, let browseButton else { return }
                self.openCodeShareBrowser(anchor: browseButton)
            }
        }
        header.packStart(child: browseButton)
        header.packEnd(child: addButton)
        let headerRef = header
        window.set(titlebar: WidgetRef(headerRef))

        let listScroll = ScrolledWindow()
        listScroll.hexpand = false
        listScroll.vexpand = true
        listScroll.setSizeRequest(width: 280, height: -1)
        listScroll.set(child: listBox)

        let detailScroll = ScrolledWindow()
        detailScroll.hexpand = true
        detailScroll.vexpand = true
        detailScroll.set(child: detailContainer)

        let paned = Paned(orientation: .horizontal)
        paned.position = 280
        paned.hexpand = true
        paned.vexpand = true
        let listScrollLocal = listScroll
        let detailScrollLocal = detailScroll
        paned.startChild = WidgetRef(listScrollLocal)
        paned.endChild = WidgetRef(detailScrollLocal)
        window.set(child: paned)

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

        showPlaceholder(message: "Select an instrument to configure.")

        listBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let row {
                    self.selectedIndex = Int(row.index)
                    self.addButton.sensitive = true
                    self.refreshDetail()
                } else {
                    self.selectedIndex = nil
                    self.addButton.sensitive = false
                    self.showPlaceholder(message: "Select an instrument to configure.")
                }
            }
        }

        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
    }

    func present() {
        installEscapeShortcut(on: window)
        window.present()
    }

    private func close() {
        window.destroy()
    }

    private func clearDetail() {
        while let child = detailContainer.firstChild {
            detailContainer.remove(child: child)
        }
    }

    private func showPlaceholder(message: String) {
        clearDetail()
        let label = Label(str: message)
        label.halign = .center
        label.valign = .center
        label.hexpand = true
        label.vexpand = true
        label.add(cssClass: "dim-label")
        label.marginStart = 24
        label.marginEnd = 24
        label.marginTop = 24
        label.marginBottom = 24
        detailContainer.append(child: label)
    }

    private func refreshDetail() {
        guard let index = selectedIndex, index < descriptors.count else {
            showPlaceholder(message: "Select an instrument to configure.")
            return
        }
        let descriptor = descriptors[index]

        clearDetail()

        let stack = Box(orientation: .vertical, spacing: 12)
        stack.marginStart = 24
        stack.marginEnd = 24
        stack.marginTop = 24
        stack.marginBottom = 24
        stack.hexpand = true
        stack.vexpand = true

        let title = Label(str: descriptor.displayName)
        title.halign = .start
        title.add(cssClass: "title-2")
        stack.append(child: title)

        let kindLabel = Label(str: "Kind: \(descriptor.kind.rawValue)")
        kindLabel.halign = .start
        kindLabel.add(cssClass: "dim-label")
        stack.append(child: kindLabel)

        let hint = Label(str: "Click Add to add this instrument. You can configure it from the sidebar afterwards.")
        hint.halign = .start
        hint.wrap = true
        hint.xalign = 0
        stack.append(child: hint)

        detailContainer.append(child: stack)
    }

    private func commit() {
        guard let index = selectedIndex, index < descriptors.count else { return }
        let descriptor = descriptors[index]
        let engine = self.engine
        let sessionID = self.sessionID
        let onAdded = self.onAdded
        let configJSON = descriptor.makeInitialConfigJSON()
        Task { @MainActor in
            let instance = await engine.addInstrument(
                kind: descriptor.kind,
                sourceIdentifier: descriptor.sourceIdentifier,
                configJSON: configJSON,
                sessionID: sessionID
            )
            onAdded?(instance)
        }
        close()
    }

    private func openCodeShareBrowser(anchor: Widget) {
        CodeShareBrowser.present(from: anchor, engine: engine, sessionID: sessionID)
        close()
    }
}
