import CGtk
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

/// A moldable list drawn as a table: rows paged in from the image as they are
/// wanted, a filter field once the collection outgrows a screenful, a thumbnail
/// where a cell hands back one. Activating a row drills into the element behind
/// it. Mirrors the SwiftUI PharoItemsList.
@MainActor
final class PharoListView {
    let widget: Box

    private let runtime: PharoRuntime
    private let object: PharoObject
    private let selector: String
    private let titles: [String]
    private let onDrill: (PharoObject) -> Void

    private let search: SearchEntry
    private let rows: ListBox
    private let groups = ColumnAlignment()
    private let showMore: Button
    private let failureLabel: Label

    private var loaded = 0
    private var total = 0
    private var fullCount = 0
    private var query = ""
    private var reloadToken = 0

    private let pageSize = 50
    private let searchThreshold = 12

    init(runtime: PharoRuntime, object: PharoObject, view: PharoViewDeclaration, onDrill: @escaping (PharoObject) -> Void) {
        self.runtime = runtime
        self.object = object
        self.selector = view.methodSelector
        self.titles = view.columns ?? []
        self.onDrill = onDrill

        search = SearchEntry()
        search.placeholderText = "Filter"
        search.marginStart = 8
        search.marginEnd = 8
        search.marginTop = 4
        search.marginBottom = 4
        search.visible = false

        rows = ListBox()
        rows.selectionMode = .single
        rows.activateOnSingleClick = false
        rows.vexpand = true
        rows.add(cssClass: "navigation-sidebar")
        rows.add(cssClass: "luma-pharo-table")

        showMore = Button()
        showMore.add(cssClass: "flat")
        showMore.halign = .start
        showMore.marginStart = 4
        showMore.visible = false

        failureLabel = Label(str: "")
        failureLabel.xalign = 0
        failureLabel.wrap = true
        failureLabel.marginStart = 8
        failureLabel.marginEnd = 8
        failureLabel.add(cssClass: "error")
        failureLabel.visible = false

        widget = Box(orientation: .vertical, spacing: 0)
        widget.append(child: search)
        widget.append(child: scroller())

        let footer = Box(orientation: .vertical, spacing: 0)
        footer.append(child: showMore)
        footer.append(child: failureLabel)
        widget.append(child: footer)

        search.onSearchChanged { [weak self] entry in
            MainActor.assumeIsolated { self?.filterChanged(to: entry.text) }
        }
        showMore.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.loadNextPage() }
        }
        rows.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated { self?.drill(into: row.getIndex()) }
        }

        reload()
    }

    private func scroller() -> ScrolledWindow {
        let inner = Box(orientation: .vertical, spacing: 0)
        if titles.count > 1 {
            inner.append(child: headerRow())
            inner.append(child: Separator(orientation: .horizontal))
        }
        inner.append(child: rows)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.propagateNaturalWidth = false
        scroll.set(child: inner)
        return scroll
    }

    private var filter: String? {
        query.isEmpty ? nil : query
    }

    /// Typing waits a beat so a burst of keystrokes coalesces into one request,
    /// while clearing the field reloads at once.
    private func filterChanged(to text: String) {
        query = text
        reloadToken += 1
        let token = reloadToken
        guard !query.isEmpty else {
            reload()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard token == self.reloadToken else { return }
            self.reload()
        }
    }

    private func reload() {
        clearRows()
        loaded = 0
        total = 0
        failureLabel.visible = false
        loadNextPage()
    }

    private func loadNextPage() {
        let token = reloadToken
        Task { @MainActor in
            do {
                let page = try await runtime.items(
                    of: object, view: selector, from: loaded + 1, count: pageSize, filter: filter)
                guard token == self.reloadToken else { return }
                for cells in page.items {
                    rows.append(child: itemRow(cells))
                }
                loaded += page.items.count
                total = page.total
                if filter == nil {
                    fullCount = page.total
                    search.visible = fullCount > searchThreshold
                }
                updateFooter()
            } catch {
                failureLabel.setText(str: error.localizedDescription)
                failureLabel.visible = true
            }
        }
    }

    private func updateFooter() {
        let remaining = total - loaded
        showMore.visible = remaining > 0
        showMore.label = "Show more (\(remaining) left)"
    }

    private func drill(into index: Int) {
        let filter = filter
        Task { @MainActor in
            do {
                let element = try await runtime.drillInto(object, view: selector, index: index + 1, filter: filter)
                onDrill(element)
            } catch {
                failureLabel.setText(str: error.localizedDescription)
                failureLabel.visible = true
            }
        }
    }

    private func headerRow() -> Box {
        let row = Box(orientation: .horizontal, spacing: 0)
        row.marginStart = 8
        row.marginEnd = 8
        row.marginTop = 4
        row.marginBottom = 4
        for (index, title) in titles.enumerated() {
            let label = cellLabel(title, expands: index == titles.count - 1)
            label.add(cssClass: "dim-label")
            label.add(cssClass: "caption-heading")
            groups.join(label, at: index)
            row.append(child: label)
        }
        return row
    }

    private func itemRow(_ cells: [PharoCell]) -> ListBoxRow {
        let line = Box(orientation: .horizontal, spacing: 0)
        line.marginStart = 8
        line.marginEnd = 8
        line.marginTop = 4
        line.marginBottom = 4
        for (index, cell) in cells.enumerated() {
            let expands = index == cells.count - 1
            line.append(child: cellWidget(cell, at: index, expands: expands, dim: cells.count > 1 && index == 0))
        }
        let row = ListBoxRow()
        row.set(child: line)
        return row
    }

    /// A thumbnail cell where the image hands one back, otherwise its text; the
    /// leading key column of a table reads dimmed the way the index does.
    private func cellWidget(_ cell: PharoCell, at index: Int, expands: Bool, dim: Bool) -> Widget {
        if let png = cell.png, let texture = IconPixbuf.makeTexture(fromPNGData: png) {
            let image = Gtk.Image(paintable: texture)
            image.pixelSize = 16
            image.halign = .start
            image.marginEnd = expands ? 0 : 16
            return image
        }
        let label = cellLabel(cell.text ?? "", expands: expands)
        label.add(cssClass: "monospace")
        if dim { label.add(cssClass: "dim-label") }
        groups.join(label, at: index)
        return label
    }

    private func cellLabel(_ text: String, expands: Bool) -> Label {
        let label = Label(str: text)
        label.xalign = 0
        label.hexpand = expands
        label.marginEnd = expands ? 0 : 16
        return label
    }

    private func clearRows() {
        while let existing = rows.getFirstChild() {
            rows.remove(child: existing)
        }
    }

    /// Keeps a table's columns aligned as rows stream in, one size group per
    /// column, headers and rows both joining it.
    private final class ColumnAlignment {
        private var groups: [SizeGroup] = []

        func join(_ label: Label, at index: Int) {
            while groups.count <= index { groups.append(SizeGroup(mode: .horizontal)) }
            groups[index].add(widget: label)
        }
    }
}
