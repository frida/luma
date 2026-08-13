import CGtk
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

/// One column of a moldable inspection: the object's print string over the views
/// it declares about itself as tabs, a list row drilling into the element behind
/// it, and a header of pane actions -- collapse, maximise, reload, close.
@MainActor
final class PharoColumnView {
    let widget: Frame

    var onDrill: (PharoObject) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onCollapse: () -> Void = {}
    var onMaximize: () -> Void = {}

    private let runtime: PharoRuntime
    private let object: PharoObject
    private let isMaximized: Bool

    init(runtime: PharoRuntime, object: PharoObject, isMaximized: Bool) {
        self.runtime = runtime
        self.object = object
        self.isMaximized = isMaximized

        widget = Frame()
        widget.hexpand = isMaximized
        widget.vexpand = true

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: header())
        column.append(child: Separator(orientation: .horizontal))
        column.append(child: tabs())
        widget.set(child: column)
    }

    private func header() -> Box {
        let title = Label(str: "\(article(object.className)) \(object.className) \(object.display)")
        title.xalign = 0
        title.hexpand = true
        title.wrap = true
        title.marginStart = 8
        title.marginTop = 6
        title.marginBottom = 6
        title.add(cssClass: "heading")

        let bar = Box(orientation: .horizontal, spacing: 2)
        bar.append(child: title)
        bar.append(child: menuButton())
        return bar
    }

    private func menuButton() -> Button {
        let button = Button(iconName: "view-more-symbolic")
        button.add(cssClass: "flat")
        button.tooltipText = "Pane actions"
        button.marginTop = 4
        button.marginBottom = 4
        button.marginEnd = 4
        button.onClicked { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                guard let self, let button else { return }
                self.presentMenu(from: button)
            }
        }
        return button
    }

    private func presentMenu(from anchor: Button) {
        var actions: [ContextMenu.Item] = []
        if isMaximized {
            actions.append(ContextMenu.Item("Restore pane") { [weak self] in self?.onMaximize() })
        } else {
            actions.append(ContextMenu.Item("Collapse pane") { [weak self] in self?.onCollapse() })
            actions.append(ContextMenu.Item("Maximize pane") { [weak self] in self?.onMaximize() })
        }
        actions.append(ContextMenu.Item("Update pane tool") { [weak self] in self?.reload() })
        let close = ContextMenu.Item("Close pane", destructive: true) { [weak self] in self?.onClose() }
        ContextMenu.present([actions, [close]], at: anchor, x: 0, y: Double(anchor.height))
    }

    private var notebook = Notebook()

    private func tabs() -> Notebook {
        notebook.hexpand = true
        notebook.vexpand = true
        notebook.scrollable = true
        reload()
        return notebook
    }

    /// The object's own views first, in priority order, then Print, then Meta
    /// at the very end -- the order the SwiftUI inspector lays its tabs in.
    private func reload() {
        while notebook.getNPages() > 0 {
            notebook.removePage(pageNum: notebook.getNPages() - 1)
        }
        Task { @MainActor in
            let views = (try? await runtime.views(of: object))?.sorted(by: { $0.priority < $1.priority }) ?? []
            for view in views where view.title != "Meta" {
                _ = notebook.appendPage(child: page(for: view), tabLabel: tabLabel(view.title))
            }
            _ = notebook.appendPage(child: textPage(object.printString), tabLabel: tabLabel("Print"))
            for view in views where view.title == "Meta" {
                _ = notebook.appendPage(child: page(for: view), tabLabel: tabLabel(view.title))
            }
        }
    }

    private func page(for view: PharoViewDeclaration) -> Box {
        switch view.viewName {
        case "list", "columnedList", "tree":
            return listPage(for: view)
        case "text":
            return textPage(view.text ?? "")
        case "graph":
            guard let graph = view.graph else { return textPage("Empty graph.") }
            return graphPage(graph, selector: view.methodSelector)
        case "chart":
            return view.chart.map(PharoVisualArea.chart) ?? textPage("Empty chart.")
        default:
            return textPage("\(view.viewName) views are not drawn yet.")
        }
    }

    private func listPage(for view: PharoViewDeclaration) -> Box {
        let titles = view.columns ?? []
        let columnGroups = ColumnGroups(headers: titles)

        let rows = ListBox()
        rows.selectionMode = .single
        rows.activateOnSingleClick = false
        rows.vexpand = true
        rows.add(cssClass: "navigation-sidebar")
        rows.add(cssClass: "luma-pharo-table")

        // Header and rows ride in one scroller so a wide table scrolls as a
        // whole and never widens the column past its set width.
        let inner = Box(orientation: .vertical, spacing: 0)
        if titles.count > 1 {
            inner.append(child: headerRow(titles, groups: columnGroups))
            inner.append(child: Separator(orientation: .horizontal))
        }
        inner.append(child: rows)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.propagateNaturalWidth = false
        scroll.set(child: inner)

        let page = Box(orientation: .vertical, spacing: 0)
        page.append(child: scroll)

        let object = object
        rows.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                let index = row.getIndex()
                Task { @MainActor in
                    if let element = try? await self.runtime.drillInto(object, view: view.methodSelector, index: index + 1) {
                        self.onDrill(element)
                    }
                }
            }
        }

        Task { @MainActor in
            guard let items = try? await runtime.items(of: object, view: view.methodSelector, from: 1, count: 100) else { return }
            for cells in items.items {
                rows.append(child: itemRow(cells, groups: columnGroups))
            }
        }
        return page
    }

    /// Aligns a table's cells by keeping a size group per column, headers and
    /// rows both joining, so the columns line up even as rows stream in.
    private final class ColumnGroups {
        private var groups: [SizeGroup]

        init(headers: [String]) {
            groups = headers.map { _ in SizeGroup(mode: .horizontal) }
        }

        func join(_ label: Label, at index: Int) {
            while groups.count <= index { groups.append(SizeGroup(mode: .horizontal)) }
            groups[index].add(widget: label)
        }
    }

    private func headerRow(_ titles: [String], groups: ColumnGroups) -> Box {
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

    private var graphAreas: [PharoGraphArea] = []

    private func graphPage(_ graph: PharoGraph, selector: String) -> Box {
        let area = PharoGraphArea(graph: graph)
        area.onDrill = { [weak self] index in
            guard let self else { return }
            Task { @MainActor in
                if let element = try? await self.runtime.drillInto(self.object, view: selector, index: index + 1) {
                    self.onDrill(element)
                }
            }
        }
        graphAreas.append(area)
        return area.widget
    }

    private func itemRow(_ cells: [PharoCell], groups: ColumnGroups) -> ListBoxRow {
        let line = Box(orientation: .horizontal, spacing: 0)
        line.marginStart = 8
        line.marginEnd = 8
        line.marginTop = 4
        line.marginBottom = 4
        if cells.count > 1 {
            for (index, cell) in cells.enumerated() {
                let label = cellLabel(cell.text ?? "", expands: index == cells.count - 1)
                label.add(cssClass: "monospace")
                groups.join(label, at: index)
                line.append(child: label)
            }
        } else {
            let label = cellLabel(cells.compactMap(\.text).joined(separator: " "), expands: true)
            label.add(cssClass: "monospace")
            line.append(child: label)
        }
        let row = ListBoxRow()
        row.set(child: line)
        return row
    }

    private func cellLabel(_ text: String, expands: Bool) -> Label {
        let label = Label(str: text)
        label.xalign = 0
        label.hexpand = expands
        label.marginEnd = expands ? 0 : 16
        return label
    }

    private func textPage(_ text: String) -> Box {
        let label = Label(str: text)
        label.selectable = true
        label.wrap = true
        label.xalign = 0
        label.yalign = 0
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 8
        label.marginBottom = 8
        label.add(cssClass: "monospace")

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: label)

        let page = Box(orientation: .vertical, spacing: 0)
        page.append(child: scroll)
        return page
    }

    private func tabLabel(_ title: String) -> Box {
        let box = Box(orientation: .horizontal, spacing: 0)
        box.append(child: Label(str: title))
        return box
    }

    private func article(_ className: String) -> String {
        "aeiouAEIOU".contains(className.first ?? "x") ? "an" : "a"
    }
}
