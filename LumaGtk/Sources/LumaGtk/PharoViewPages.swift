import CGtk
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

@MainActor
final class PharoViewPages {
    private let source: any PharoViewSource
    private let onDrill: (PharoObject) -> Void

    private var listViews: [PharoListView] = []
    private var graphAreas: [PharoGraphArea] = []
    private var chartAreas: [PharoChartArea] = []
    private var canvasAreas: [PharoCanvasArea] = []
    private var patternPages: [AnyObject] = []

    private static let releasedPattern = "The host no longer holds this value."

    init(source: any PharoViewSource, onDrill: @escaping (PharoObject) -> Void) {
        self.source = source
        self.onDrill = onDrill
    }

    func page(for view: PharoViewDeclaration) -> Widget {
        switch view.viewName {
        case "list", "columnedList", "tree":
            return listPage(for: view)
        case "text":
            return Self.textPage(view.text ?? "")
        case "graph":
            guard let graph = view.graph else { return Self.textPage("Empty graph.") }
            return graphPage(graph, selector: view.methodSelector)
        case "chart":
            guard let chart = view.chart else { return Self.textPage("Empty chart.") }
            return chartPage(chart, selector: view.methodSelector)
        case "canvas":
            guard let canvas = view.canvas else { return Self.textPage("Empty canvas.") }
            return canvasPage(scene: canvas.scene)
        case "lumaBytes":
            guard let bytes = PharoBytesReference(view.text ?? "") else { return Self.textPage("These bytes could not be read.") }
            return bytesPage(bytes)
        case "lumaPatternBytes":
            guard let target = PharoPatternTarget(reference: view.text ?? "") else { return Self.textPage(Self.releasedPattern) }
            return patternBytesPage(target)
        case "lumaPatternVisualization":
            guard let target = PharoPatternTarget(reference: view.text ?? "") else { return Self.textPage(Self.releasedPattern) }
            return patternVisualizationPage(target)
        default:
            return Self.textPage("\(view.viewName) views are not drawn yet.")
        }
    }

    private func listPage(for view: PharoViewDeclaration) -> Widget {
        let list = PharoListView(source: source, view: view) { [weak self] element in
            self?.onDrill(element)
        }
        listViews.append(list)
        return list.widget
    }

    private func graphPage(_ graph: PharoGraph, selector: String) -> Box {
        let area = PharoGraphArea(graph: graph)
        area.onDrill = { [weak self] index in
            guard let self else { return }
            Task { @MainActor in
                if let element = try? await self.source.drill(view: selector, index: index + 1, filter: nil) {
                    self.onDrill(element)
                }
            }
        }
        graphAreas.append(area)
        return area.widget
    }

    private func chartPage(_ chart: PharoChart, selector: String) -> Box {
        let area = PharoChartArea(chart: chart)
        area.onDrill = { [weak self] index in
            guard let self else { return }
            Task { @MainActor in
                if let element = try? await self.source.drill(view: selector, index: index + 1, filter: nil) {
                    self.onDrill(element)
                }
            }
        }
        chartAreas.append(area)
        return area.widget
    }

    /// The scene is the host's already; the view only says which one, and the
    /// widget follows it as the image changes it.
    private func canvasPage(scene: Int) -> Widget {
        let canvas = PharoCanvasArea(scene: scene)
        canvasAreas.append(canvas)
        return canvas.widget
    }

    private func bytesPage(_ bytes: PharoBytesReference) -> Widget {
        let hexView = HexView(bytes: bytes.data, baseAddress: bytes.address)
        hexView.widget.marginStart = 8
        hexView.widget.marginTop = 8
        patternPages.append(hexView)
        let scroll = ScrolledWindow()
        scroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .automatic)
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: hexView.widget)
        return scroll
    }

    private func patternBytesPage(_ target: PharoPatternTarget) -> Widget {
        let page = PharoPatternBytesPage(target: target)
        patternPages.append(page)
        return page.widget
    }

    private func patternVisualizationPage(_ target: PharoPatternTarget) -> Widget {
        let visualization: PatternVisualization
        do {
            visualization = try PatternVisualization(target.node.visualizer!, of: target.node, in: target.decoding.root)
        } catch {
            return Self.failurePage(error.localizedDescription)
        }
        let view = PatternVisualizationWidget(visualization)
        patternPages.append(view)
        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: view.widget)
        return scroll
    }

    static func textPage(_ text: String) -> Box {
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

    static func failurePage(_ message: String) -> Box {
        let label = Label(str: message)
        label.selectable = true
        label.wrap = true
        label.xalign = 0
        label.yalign = 0
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 8
        label.marginBottom = 8
        label.add(cssClass: "monospace")
        label.add(cssClass: "error")

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: label)

        let page = Box(orientation: .vertical, spacing: 0)
        page.append(child: scroll)
        return page
    }
}
