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

    private func menuButton() -> MenuButton {
        let button = MenuButton()
        button.add(cssClass: "flat")
        button.iconName = "view-more-symbolic"
        button.tooltipText = "Pane actions"
        button.marginTop = 4
        button.marginBottom = 4
        button.marginEnd = 4

        let popover = Popover()
        popover.autohide = true
        let box = Box(orientation: .vertical, spacing: 2)
        box.marginTop = 6
        box.marginBottom = 6
        box.marginStart = 6
        box.marginEnd = 6
        if isMaximized {
            box.append(child: menuItem("Restore pane", popover) { [weak self] in self?.onMaximize() })
        } else {
            box.append(child: menuItem("Collapse pane", popover) { [weak self] in self?.onCollapse() })
            box.append(child: menuItem("Maximize pane", popover) { [weak self] in self?.onMaximize() })
        }
        box.append(child: menuItem("Update pane tool", popover) { [weak self] in self?.reload() })
        box.append(child: Separator(orientation: .horizontal))
        let close = menuItem("Close pane", popover) { [weak self] in self?.onClose() }
        close.add(cssClass: "destructive-action")
        box.append(child: close)
        popover.set(child: box)
        button.set(popover: popover)
        return button
    }

    private func menuItem(_ label: String, _ popover: Popover, _ action: @escaping () -> Void) -> Button {
        let button = Button(label: label)
        button.add(cssClass: "flat")
        button.hexpand = true
        if let child = button.child { child.halign = .start }
        button.onClicked { _ in
            MainActor.assumeIsolated {
                popover.popdown()
                action()
            }
        }
        return button
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
        let rows = ListBox()
        rows.selectionMode = .single
        rows.activateOnSingleClick = false
        rows.add(cssClass: "navigation-sidebar")

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: rows)

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
            guard let page = try? await runtime.items(of: object, view: view.methodSelector, from: 1, count: 100) else { return }
            for cells in page.items {
                rows.append(child: itemRow(cells))
            }
        }
        return page
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

    private func itemRow(_ cells: [PharoCell]) -> ListBoxRow {
        let label = Label(str: cells.compactMap(\.text).joined(separator: "     "))
        label.xalign = 0
        label.marginStart = 8
        label.marginEnd = 8
        label.marginTop = 4
        label.marginBottom = 4
        label.add(cssClass: "monospace")
        let row = ListBoxRow()
        row.set(child: label)
        return row
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
