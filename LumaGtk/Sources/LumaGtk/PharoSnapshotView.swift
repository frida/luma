import CGtk
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

/// What a cell's last run produced, drawn with no VM around: the same shape as
/// the live inspector, minus the drilling a snapshot has no objects for.
/// Mirrors the SwiftUI PharoSnapshotView.
@MainActor
final class PharoSnapshotView {
    let widget: Box

    private let snapshot: PharoSnapshot
    private var chartAreas: [PharoChartArea] = []
    private var canvasAreas: [PharoCanvasArea] = []
    private var graphAreas: [PharoGraphArea] = []

    init(snapshot: PharoSnapshot) {
        self.snapshot = snapshot

        widget = Box(orientation: .vertical, spacing: 0)
        widget.add(cssClass: "luma-pharo-body")
        widget.hexpand = true
        widget.append(child: header())
        widget.append(child: Separator(orientation: .horizontal))

        let notebook = Notebook()
        notebook.hexpand = true
        notebook.scrollable = true
        notebook.showTabs = snapshot.views.count > 1
        for view in snapshot.views.sorted(by: { $0.priority < $1.priority }) {
            _ = notebook.appendPage(child: content(of: view), tabLabel: tabLabel(view.title))
        }
        widget.append(child: notebook)
    }

    private func tabLabel(_ title: String) -> Box {
        let box = Box(orientation: .horizontal, spacing: 0)
        box.append(child: Label(str: title))
        return box
    }

    private func header() -> Box {
        let box = Box(orientation: .vertical, spacing: 2)
        box.marginStart = 8
        box.marginEnd = 8
        box.marginTop = 8
        box.marginBottom = 8

        let title = Label(str: snapshot.printString)
        title.xalign = 0
        title.wrap = true
        title.lines = 2
        title.ellipsize = .end
        title.add(cssClass: "heading")

        let className = Label(str: snapshot.className)
        className.xalign = 0
        className.add(cssClass: "caption")
        className.add(cssClass: "dim-label")

        box.append(child: title)
        box.append(child: className)
        return box
    }

    private func content(of view: PharoSnapshot.View) -> Widget {
        switch view.content {
        case .items(let kept, let total):
            return itemsPage(kept, total: total)
        case .text(let text):
            return textPage(text)
        case .graph(let graph):
            let area = PharoGraphArea(graph: graph)
            graphAreas.append(area)
            return area.widget
        case .chart(let chart):
            let area = PharoChartArea(chart: chart)
            chartAreas.append(area)
            return area.widget
        case .canvas(let scene):
            let area = PharoCanvasArea(scene: scene)
            canvasAreas.append(area)
            return area.widget
        case .empty:
            return textPage("Nothing captured.")
        }
    }

    private func itemsPage(_ kept: [[PharoSnapshot.View.Cell]], total: Int) -> Box {
        let rows = ListBox()
        rows.selectionMode = .none
        rows.add(cssClass: "navigation-sidebar")
        rows.add(cssClass: "luma-pharo-table")
        for cells in kept {
            rows.append(child: itemRow(cells))
        }

        let stack = Box(orientation: .vertical, spacing: 0)
        stack.append(child: rows)
        if kept.count < total {
            let more = Label(str: "\(total - kept.count) more, kept out of the snapshot")
            more.xalign = 0
            more.marginStart = 8
            more.marginTop = 4
            more.marginBottom = 4
            more.add(cssClass: "caption")
            more.add(cssClass: "dim-label")
            stack.append(child: more)
        }

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.propagateNaturalWidth = false
        scroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .automatic)
        scroll.set(child: stack)

        let page = Box(orientation: .vertical, spacing: 0)
        page.append(child: scroll)
        return page
    }

    private func itemRow(_ cells: [PharoSnapshot.View.Cell]) -> ListBoxRow {
        let line = Box(orientation: .horizontal, spacing: 0)
        line.marginStart = 8
        line.marginEnd = 8
        line.marginTop = 4
        line.marginBottom = 4
        for (index, cell) in cells.enumerated() {
            let expands = index == cells.count - 1
            if let png = cell.png, let texture = IconPixbuf.makeTexture(fromPNGData: png) {
                let image = Gtk.Image(paintable: texture)
                image.pixelSize = 16
                image.halign = .start
                image.marginEnd = expands ? 0 : 16
                line.append(child: image)
            } else {
                let label = Label(str: cell.text ?? "")
                label.xalign = 0
                label.hexpand = expands
                label.marginEnd = expands ? 0 : 16
                label.add(cssClass: "monospace")
                if cells.count > 1 && index == 0 { label.add(cssClass: "dim-label") }
                line.append(child: label)
            }
        }
        let row = ListBoxRow()
        row.set(child: line)
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
        scroll.propagateNaturalWidth = false
        scroll.set(child: label)

        let page = Box(orientation: .vertical, spacing: 0)
        page.append(child: scroll)
        return page
    }
}
