import Foundation
import Gdk
import Gtk

@MainActor
final class SidebarBrowserPopover<Item> {
    private enum Entry {
        case sectionHeader(String)
        case item(Item)
    }

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
    private var entries: [Entry] = []
    private var query: String = ""
    private var filterTask: Task<Void, Never>?
    private var refreshGeneration: UInt = 0
    private var isChoosing = false

    // Cap first paint so Windows GTK is not forced to allocate a huge ListBox
    // while the popover is still mapping.
    private static var visibleRowLimit: Int { 150 }

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
                    self?.scheduleDismiss()
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
                self?.query = entry.text
                self?.scheduleRefresh()
            }
        }
        searchEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.chooseFirstMatch() }
        }
        searchEntry.onStopSearch { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDismiss() }
        }
        column.append(child: searchEntry)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.hasFrame = false

        let listBox = ListBox()
        listBox.selectionMode = .none
        listBox.add(cssClass: "navigation-sidebar")
        listBox.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                let index = Int(row.index)
                guard index >= 0, index < self.entries.count else { return }
                if case .item(let item) = self.entries[index] {
                    // Defer dismiss/unparent until after row-activated finishes;
                    // tearing the popover down mid-emission faults inside GTK.
                    self.scheduleChoose(item)
                }
            }
        }
        scroll.set(child: listBox)
        column.append(child: scroll)

        popover.set(child: column)
        popover.set(parent: WidgetRef(anchor))

        self.popover = popover
        self.listBox = listBox

        // Map the empty popover first, then fill rows on a later turn so the
        // initial present is not competing with a large ListBox rebuild.
        popover.popup()
        _ = searchEntry.grabFocus()
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.popover != nil else { return }
            self.refreshList()
        }
    }

    private func scheduleRefresh() {
        filterTask?.cancel()
        filterTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            self.refreshList()
        }
    }

    private func refreshList() {
        guard let listBox else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let matching = filteredItems()
        let limit = Self.visibleRowLimit
        let visible = Array(matching.prefix(limit))
        let truncated = matching.count > limit

        clearListBox(listBox)

        entries = []
        var previousGroup: String?
        for item in visible {
            guard generation == refreshGeneration else { return }
            let group = groupName(item)
            if group != previousGroup {
                entries.append(.sectionHeader(group))
                listBox.append(child: makeSectionHeaderRow(name: group))
                previousGroup = group
            }
            entries.append(.item(item))
            listBox.append(child: makeItemRow(item))
        }

        if matching.isEmpty {
            listBox.append(child: makeEmptyRow())
        } else if truncated {
            listBox.append(child: makeTruncationRow(shown: visible.count, total: matching.count))
        }
    }

    private func clearListBox(_ listBox: ListBox) {
        while let child = listBox.firstChild {
            listBox.remove(child: child)
        }
    }

    private func makeSectionHeaderRow(name: String) -> ListBoxRow {
        let row = ListBoxRow()
        row.selectable = false
        row.activatable = false
        row.canFocus = false
        let label = Label(str: name)
        label.halign = .start
        label.add(cssClass: "caption-heading")
        label.add(cssClass: "dim-label")
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 6
        label.marginBottom = 2
        row.set(child: label)
        return row
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

    private func makeEmptyRow() -> ListBoxRow {
        let row = ListBoxRow()
        row.selectable = false
        let label = Label(str: emptyMessage)
        label.halign = .start
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 6
        label.marginBottom = 6
        label.add(cssClass: "dim-label")
        row.set(child: label)
        return row
    }

    private func makeTruncationRow(shown: Int, total: Int) -> ListBoxRow {
        let row = ListBoxRow()
        row.selectable = false
        row.activatable = false
        let label = Label(str: "Showing \(shown) of \(total). Refine the filter to see more.")
        label.halign = .start
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 6
        label.marginBottom = 6
        label.wrap = true
        label.add(cssClass: "dim-label")
        label.add(cssClass: "caption")
        row.set(child: label)
        return row
    }

    private func filteredItems() -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { matches($0, trimmed) }
    }

    private func chooseFirstMatch() {
        for entry in entries {
            if case .item(let item) = entry {
                scheduleChoose(item)
                return
            }
        }
    }

    private func scheduleChoose(_ item: Item) {
        guard !isChoosing else { return }
        isChoosing = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.dismiss()
            self.onChoose(item)
        }
    }

    private func scheduleDismiss() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard popover != nil else { return }
        popover?.popdown()
        cleanup()
    }

    private func cleanup() {
        filterTask?.cancel()
        filterTask = nil
        refreshGeneration &+= 1
        isChoosing = false
        if let popover {
            popover.unparent()
        }
        popover = nil
        listBox = nil
        retainer = nil
    }
}
