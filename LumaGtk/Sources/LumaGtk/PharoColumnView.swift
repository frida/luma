import CGtk
import Foundation
import Gtk
import GtkSource
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
    private let highlight: (GtkSource.Buffer) -> Void

    init(
        runtime: PharoRuntime,
        object: PharoObject,
        isMaximized: Bool,
        highlight: @escaping (GtkSource.Buffer) -> Void
    ) {
        self.runtime = runtime
        self.object = object
        self.isMaximized = isMaximized
        self.highlight = highlight

        widget = Frame()
        widget.hexpand = isMaximized
        widget.vexpand = true

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: header())
        column.append(child: Separator(orientation: .horizontal))
        column.append(child: object.isClass ? classBrowserBody(of: object) : tabs())
        widget.set(child: column)
    }

    private var classBrowsers: [PharoClassBrowser] = []

    private func classBrowserBody(of classObject: PharoObject) -> Widget {
        let browser = PharoClassBrowser(
            runtime: runtime, classObject: classObject, onSelect: onDrill, highlight: highlight)
        classBrowsers.append(browser)
        return browser.widget
    }

    private func header() -> Box {
        let title = Label(str: "\(article(object.className)) \(object.className) \(object.display)")
        title.xalign = 0
        title.hexpand = true
        title.wrap = true
        title.lines = 2
        title.ellipsize = .end
        title.marginStart = 8
        title.marginTop = 6
        title.marginBottom = 6
        title.add(cssClass: "heading")

        let bar = Box(orientation: .horizontal, spacing: 2)
        bar.append(child: title)
        bar.append(child: menuButton())
        return bar
    }

    private enum PaneMode {
        case menu
        case collapse
        case close
    }

    private lazy var paneButton = makePaneButton()
    private var modifierToken: UInt?

    private func menuButton() -> Button {
        let button = paneButton
        button.onMap { [weak self] _ in
            MainActor.assumeIsolated { self?.watchModifiers() }
        }
        button.onUnmap { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetModifiers() }
        }
        return button
    }

    private func makePaneButton() -> Button {
        let button = Button(iconName: "view-more-symbolic")
        button.add(cssClass: "flat")
        button.tooltipText = "Pane actions"
        button.marginTop = 4
        button.marginBottom = 4
        button.marginEnd = 4
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.activatePane() }
        }
        return button
    }

    private func watchModifiers() {
        refreshPaneButton()
        guard modifierToken == nil else { return }
        modifierToken = PharoModifierWatcher.subscribe { [weak self] in self?.refreshPaneButton() }
    }

    private func forgetModifiers() {
        modifierToken.map(PharoModifierWatcher.unsubscribe)
        modifierToken = nil
    }

    /// Holding the primary key over the pane says it will collapse; adding Shift
    /// says it will close. With nothing held the button just opens the menu.
    private var paneMode: PaneMode {
        if PharoModifierWatcher.primaryHeld, PharoModifierWatcher.shiftHeld { return .close }
        if PharoModifierWatcher.primaryHeld, !isMaximized { return .collapse }
        return .menu
    }

    private func refreshPaneButton() {
        switch paneMode {
        case .menu:
            paneButton.iconName = "view-more-symbolic"
            paneButton.tooltipText = "Pane actions"
        case .collapse:
            paneButton.iconName = "window-minimize-symbolic"
            paneButton.tooltipText = "Collapse pane"
        case .close:
            paneButton.iconName = "window-close-symbolic"
            paneButton.tooltipText = "Close pane"
        }
    }

    private func activatePane() {
        switch paneMode {
        case .menu:
            presentMenu(from: paneButton)
        case .collapse:
            onCollapse()
            PharoModifierWatcher.reset()
        case .close:
            onClose()
            PharoModifierWatcher.reset()
        }
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
            // The image's own Meta view is dropped for the coder shown on the
            // object's class, the way the SwiftUI inspector synthesises it.
            if let receiverClass = try? await runtime.classObject(of: object) {
                _ = notebook.appendPage(child: classBrowserBody(of: receiverClass), tabLabel: tabLabel("Meta"))
            }
        }
    }

    private func page(for view: PharoViewDeclaration) -> Widget {
        switch view.viewName {
        case "list", "columnedList", "tree":
            return listPage(for: view)
        case "text":
            return textPage(view.text ?? "")
        case "graph":
            guard let graph = view.graph else { return textPage("Empty graph.") }
            return graphPage(graph, selector: view.methodSelector)
        case "chart":
            guard let chart = view.chart else { return textPage("Empty chart.") }
            let area = PharoChartArea(chart: chart)
            chartAreas.append(area)
            return area.widget
        default:
            return textPage("\(view.viewName) views are not drawn yet.")
        }
    }

    private func listPage(for view: PharoViewDeclaration) -> Widget {
        let list = PharoListView(runtime: runtime, object: object, view: view) { [weak self] element in
            self?.onDrill(element)
        }
        listViews.append(list)
        return list.widget
    }

    private var listViews: [PharoListView] = []
    private var graphAreas: [PharoGraphArea] = []
    private var chartAreas: [PharoChartArea] = []

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
