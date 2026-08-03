import CGtk
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

/// A moldable inspection drawn as Miller columns: each drilled object a column
/// beside the last, any pane shrunk to a strip or blown up to fill, and a pager
/// strip over them that marks and reaches each column. Mirrors the SwiftUI
/// inspector against the same runtime.
@MainActor
final class PharoColumnsView {
    let widget: Box

    private let runtime: PharoRuntime
    private let state = PharoColumnState()
    private let strip: Box
    private let columns: Box
    private let scroll: ScrolledWindow
    private var columnWidth = 380
    private var columnViews: [PharoColumnView] = []

    init(runtime: PharoRuntime) {
        self.runtime = runtime

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        strip = Box(orientation: .horizontal, spacing: 3)
        strip.halign = .center
        strip.marginTop = 4
        strip.marginBottom = 4

        columns = Box(orientation: .horizontal, spacing: 0)
        columns.hexpand = true
        columns.vexpand = true

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .never)
        scroll.set(child: columns)

        widget.append(child: strip)
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: scroll)
    }

    func present(_ object: PharoObject) {
        state.startOver(at: object)
        render()
    }

    func showMessage(_ text: String) {
        state.clear()
        clear(strip)
        clear(columns)
        let label = Label(str: text)
        label.marginStart = 12
        label.marginTop = 12
        label.xalign = 0
        label.yalign = 0
        label.selectable = true
        label.wrap = true
        label.hexpand = true
        label.add(cssClass: "monospace")
        columns.append(child: label)
    }

    private func render() {
        clear(strip)
        clear(columns)
        columnViews.removeAll()
        renderStrip()

        if let handle = state.maximized, let depth = state.objects.firstIndex(where: { $0.handle == handle }) {
            columns.append(child: column(at: depth, maximized: true).widget)
            return
        }

        var depth = 0
        while depth < state.objects.count {
            if state.isCollapsed(state.objects[depth].handle) {
                let start = depth
                while depth < state.objects.count, state.isCollapsed(state.objects[depth].handle) { depth += 1 }
                columns.append(child: collapsedStack(from: start, to: depth))
            } else {
                let view = column(at: depth, maximized: false)
                view.widget.setSizeRequest(width: columnWidth, height: -1)
                columns.append(child: view.widget)
                depth += 1
            }
        }
    }

    /// The views own the row and header handlers, so they have to outlive this
    /// call; keeping only their widgets would let them deallocate and leave the
    /// drill and pane actions dead.
    private func column(at depth: Int, maximized: Bool) -> PharoColumnView {
        let object = state.objects[depth]
        let view = PharoColumnView(runtime: runtime, object: object, isMaximized: maximized)
        columnViews.append(view)
        view.onDrill = { [weak self] element in
            self?.state.open(element, from: depth)
            self?.render()
        }
        view.onClose = { [weak self] in
            self?.state.close(from: depth)
            self?.render()
        }
        view.onCollapse = { [weak self] in
            self?.state.toggleCollapsed(object.handle)
            self?.render()
        }
        view.onMaximize = { [weak self] in
            self?.state.toggleMaximized(object.handle)
            self?.render()
        }
        return view
    }

    private func collapsedStack(from start: Int, to end: Int) -> Box {
        let stack = Box(orientation: .vertical, spacing: 6)
        stack.valign = .center
        stack.marginStart = 8
        stack.marginEnd = 8
        for depth in start..<end {
            let object = state.objects[depth]
            let badge = Button()
            badge.add(cssClass: "flat")
            badge.setSizeRequest(width: 24, height: 28)
            badge.tooltipText = "Expand \(object.className)"
            badge.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.state.toggleCollapsed(object.handle)
                    self?.render()
                }
            }
            stack.append(child: badge)
        }
        return stack
    }

    private func renderStrip() {
        for (depth, object) in state.objects.enumerated() {
            let square = Button()
            square.setSizeRequest(width: 22, height: 12)
            square.tooltipText = object.printString
            if state.isMaximized(object.handle) {
                square.add(cssClass: "suggested-action")
            } else if state.isCollapsed(object.handle) {
                square.add(cssClass: "flat")
            }
            square.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.state.isCollapsed(object.handle) {
                        self.state.toggleCollapsed(object.handle)
                        self.render()
                    }
                }
            }
            strip.append(child: square)
            _ = depth
        }
    }

    private func clear(_ box: Box) {
        while let existing = box.getFirstChild() {
            box.remove(child: existing)
        }
    }
}
