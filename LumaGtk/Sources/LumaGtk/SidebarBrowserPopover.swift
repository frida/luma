import Foundation
import Gdk
import Gtk

@MainActor
final class SidebarBrowserPopover<Item> {
    private let items: [Item]
    private let placeholder: String
    private let emptyMessage: String
    private let groupName: (Item) -> String
    private let title: (Item) -> String
    private let tooltip: (Item) -> String?
    private let dimmed: (Item) -> Bool
    private let matches: (Item, String) -> Bool
    private let onChoose: (Item) -> Void

    private var retainer: SidebarBrowserPopover?
    private var popover: Popover?
    private var listBox: ListBox?
    private var query: String = ""

    init(
        items: [Item],
        placeholder: String,
        emptyMessage: String,
        groupName: @escaping (Item) -> String,
        title: @escaping (Item) -> String,
        tooltip: @escaping (Item) -> String? = { _ in nil },
        dimmed: @escaping (Item) -> Bool = { _ in false },
        matches: @escaping (Item, String) -> Bool,
        onChoose: @escaping (Item) -> Void
    ) {
        self.items = items
        self.placeholder = placeholder
        self.emptyMessage = emptyMessage
        self.groupName = groupName
        self.title = title
        self.tooltip = tooltip
        self.dimmed = dimmed
        self.matches = matches
        self.onChoose = onChoose
    }

    func presentAnchored(to anchor: WidgetProtocol) {
        retainer = self
        // Pop up after the list-row signal that triggered us finishes emitting;
        // grabbing and reparenting mid-emission faults inside GTK.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.buildAndPresent(anchoredTo: anchor)
        }
    }

    private func buildAndPresent(anchoredTo anchor: WidgetProtocol) {
        let popover = Popover()
        popover.autohide = true
        popover.position = .right
        popover.onClosed { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanup() }
        }

        let key = EventControllerKey()
        key.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                if Int32(keyval) == Gdk.keyEscape {
                    self?.dismiss()
                    return true
                }
                return false
            }
        }
        popover.install(controller: key)

        let column = Box(orientation: .vertical, spacing: 8)
        column.marginStart = 8
        column.marginEnd = 8
        column.marginTop = 8
        column.marginBottom = 8
        column.setSizeRequest(width: 320, height: 380)

        let searchEntry = SearchEntry()
        searchEntry.placeholderText = placeholder
        searchEntry.hexpand = true
        searchEntry.onSearchChanged { [weak self] entry in
            MainActor.assumeIsolated {
                self?.query = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.listBox?.invalidateFilter()
            }
        }
        searchEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.chooseFirstMatch() }
        }
        searchEntry.onStopSearch { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        column.append(child: searchEntry)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.hasFrame = false

        let listBox = ListBox()
        listBox.selectionMode = .none
        listBox.add(cssClass: "navigation-sidebar")
        listBox.set(placeholder: makeEmptyLabel())
        listBox.setFilterFunc { [weak self] row in
            MainActor.assumeIsolated {
                guard let self else { return false }
                return self.isVisible(self.items[Int(row.index)])
            }
        }
        listBox.setHeaderFunc { [weak self] row, previous in
            MainActor.assumeIsolated {
                self?.updateHeader(of: row, following: previous)
            }
        }
        listBox.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.choose(self.items[Int(row.index)])
            }
        }
        scroll.set(child: listBox)
        column.append(child: scroll)

        popover.set(child: column)
        popover.set(parent: WidgetRef(anchor))

        self.popover = popover
        self.listBox = listBox

        for item in items {
            listBox.append(child: makeItemRow(item))
        }

        popover.popup()
        _ = searchEntry.grabFocus()
    }

    private func isVisible(_ item: Item) -> Bool {
        query.isEmpty || matches(item, query)
    }

    private func updateHeader(of row: ListBoxRowRef, following previous: ListBoxRowRef?) {
        let group = groupName(items[Int(row.index)])
        guard let previous, groupName(items[Int(previous.index)]) == group else {
            row.set(header: makeSectionHeader(name: group))
            return
        }
        row.set(header: WidgetRef?.none)
    }

    private func chooseFirstMatch() {
        guard let item = items.first(where: isVisible) else { return }
        choose(item)
    }

    private func choose(_ item: Item) {
        dismiss()
        onChoose(item)
    }

    private func dismiss() {
        popover?.popdown()
        cleanup()
    }

    private func cleanup() {
        popover?.unparent()
        popover = nil
        listBox = nil
        retainer = nil
    }

    private func makeItemRow(_ item: Item) -> ListBoxRow {
        let row = ListBoxRow()
        let box = Box(orientation: .horizontal, spacing: 6)
        box.marginStart = 12
        box.marginEnd = 12
        box.marginTop = 4
        box.marginBottom = 4
        let label = Label(str: title(item))
        label.halign = .start
        label.hexpand = true
        label.ellipsize = .end
        box.append(child: label)
        if dimmed(item) {
            box.opacity = 0.5
        }
        box.tooltipText = tooltip(item)
        row.set(child: box)
        return row
    }

    private func makeSectionHeader(name: String) -> Label {
        let label = Label(str: name)
        label.halign = .start
        label.add(cssClass: "caption-heading")
        label.add(cssClass: "dim-label")
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 6
        label.marginBottom = 2
        return label
    }

    private func makeEmptyLabel() -> Label {
        let label = Label(str: emptyMessage)
        label.halign = .start
        label.add(cssClass: "dim-label")
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 6
        label.marginBottom = 6
        return label
    }
}
