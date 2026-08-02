import CGtk
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

/// A moldable inspector for a Pharo object: the views it declares about itself
/// as tabs, each drawn natively, with a row drilling into the element behind it
/// and a back step returning to where it came from. Mirrors the SwiftUI
/// inspector against the same runtime, with GTK widgets in place of the columns.
@MainActor
final class PharoInspectorPane {
    let widget: Box

    private let runtime: PharoRuntime
    private let backButton: Button
    private let titleLabel: Label
    private let content: Box
    private var trail: [PharoObject] = []

    init(runtime: PharoRuntime) {
        self.runtime = runtime

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        backButton = Button(label: "‹ Back")
        backButton.sensitive = false
        backButton.marginStart = 12
        backButton.marginTop = 8
        backButton.marginBottom = 8

        titleLabel = Label(str: "")
        titleLabel.xalign = 0
        titleLabel.hexpand = true
        titleLabel.marginEnd = 12
        titleLabel.add(cssClass: "monospace")

        let header = Box(orientation: .horizontal, spacing: 8)
        header.append(child: backButton)
        header.append(child: titleLabel)

        content = Box(orientation: .vertical, spacing: 0)
        content.hexpand = true
        content.vexpand = true

        widget.append(child: header)
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: content)

        backButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.stepBack() }
        }
    }

    func present(_ object: PharoObject) {
        trail = [object]
        render()
    }

    func showMessage(_ text: String) {
        trail = []
        backButton.sensitive = false
        titleLabel.text = ""
        fill(content, with: textPage(text))
    }

    private func drill(into object: PharoObject) {
        trail.append(object)
        render()
    }

    private func stepBack() {
        guard trail.count > 1 else { return }
        trail.removeLast()
        render()
    }

    private func render() {
        guard let object = trail.last else { return }
        backButton.sensitive = trail.count > 1
        titleLabel.text = object.display.isEmpty ? object.printString : object.display

        let notebook = Notebook()
        notebook.hexpand = true
        notebook.vexpand = true
        notebook.scrollable = true
        _ = notebook.appendPage(child: textPage(object.printString), tabLabel: tabLabel("Print"))
        fill(content, with: notebook)

        Task { @MainActor in
            let views = (try? await runtime.views(of: object)) ?? []
            for view in views.sorted(by: { $0.priority < $1.priority }) where view.title != "Meta" {
                _ = notebook.appendPage(child: page(for: view, of: object), tabLabel: tabLabel(view.title))
            }
        }
    }

    private func page(for view: PharoViewDeclaration, of object: PharoObject) -> Box {
        switch view.viewName {
        case "list", "columnedList", "tree":
            return listPage(for: view, of: object)
        case "text":
            return textPage(view.text ?? "")
        case "graph":
            return view.graph.map(PharoVisualArea.graph) ?? textPage("Empty graph.")
        case "chart":
            return view.chart.map(PharoVisualArea.chart) ?? textPage("Empty chart.")
        default:
            return textPage("\(view.viewName) views are not drawn yet.")
        }
    }

    private func listPage(for view: PharoViewDeclaration, of object: PharoObject) -> Box {
        let rows = ListBox()
        rows.selectionMode = .single
        rows.add(cssClass: "navigation-sidebar")

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: rows)

        let page = Box(orientation: .vertical, spacing: 0)
        page.append(child: scroll)

        rows.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                let index = row.getIndex()
                Task { @MainActor in
                    if let element = try? await self.runtime.drillInto(object, view: view.methodSelector, index: index + 1) {
                        self.drill(into: element)
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

    private func fill(_ box: Box, with child: some WidgetProtocol) {
        while let existing = box.getFirstChild() {
            box.remove(child: existing)
        }
        box.append(child: child)
    }
}
