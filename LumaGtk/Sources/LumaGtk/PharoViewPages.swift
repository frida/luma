import CGtk
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

@MainActor
final class PharoViewPages {
    var onClose: () -> Void = {}

    private let source: any PharoViewSource
    private let runtime: PharoRuntime
    private weak var engine: Engine?
    private let onDrill: (PharoObject) -> Void

    private var shown: [String: Shown] = [:]

    private static let releasedPattern = "The host no longer holds this value."

    private struct Shown {
        let viewName: String
        let page: Widget
        let owner: AnyObject?
        let follows: (PharoViewDeclaration) -> Bool
    }

    init(source: any PharoViewSource, runtime: PharoRuntime, engine: Engine?, onDrill: @escaping (PharoObject) -> Void) {
        self.source = source
        self.runtime = runtime
        self.engine = engine
        self.onDrill = onDrill
    }

    func page(for view: PharoViewDeclaration) -> Widget {
        let built = build(view)
        shown[view.methodSelector] = built
        return built.page
    }

    func refreshed(_ view: PharoViewDeclaration) -> (page: Widget, replacing: Widget?) {
        let current = shown[view.methodSelector]
        if let current, current.viewName == view.viewName, current.follows(view) {
            return (current.page, nil)
        }
        return (page(for: view), current?.page)
    }

    private func build(_ view: PharoViewDeclaration) -> Shown {
        switch view.viewName {
        case "list", "columnedList", "tree":
            return listPage(for: view)
        case "text":
            return textViewPage(view)
        case "graph":
            guard let graph = view.graph else { return unchanged(Self.textPage("Empty graph."), while: view) { $0.graph == nil } }
            return graphPage(graph, selector: view.methodSelector)
        case "chart":
            guard let chart = view.chart else { return unchanged(Self.textPage("Empty chart."), while: view) { $0.chart == nil } }
            return chartPage(chart, selector: view.methodSelector)
        case "canvas":
            guard let canvas = view.canvas else { return unchanged(Self.textPage("Empty canvas."), while: view) { $0.canvas == nil } }
            return canvasPage(scene: canvas.scene)
        case "lumaBytes":
            guard let bytes = PharoBytesReference(view.text ?? "") else {
                return unchanged(Self.textPage("These bytes could not be read."), while: view) { $0.text == view.text }
            }
            return bytesPage(bytes, while: view)
        case "lumaPatternBytes":
            guard let target = PharoPatternTarget(reference: view.text ?? "") else {
                return unchanged(Self.textPage(Self.releasedPattern), while: view) { $0.text == view.text }
            }
            return patternBytesPage(target, while: view)
        case "lumaPatternVisualization":
            guard let target = PharoPatternTarget(reference: view.text ?? "") else {
                return unchanged(Self.textPage(Self.releasedPattern), while: view) { $0.text == view.text }
            }
            return patternVisualizationPage(target, while: view)
        case "lumaDisassembly" where engine != nil:
            let page = PharoDisassemblyPage(engine: engine!, reference: view.text ?? "", runtime: runtime) { [weak self] object in
                self?.onDrill(object)
            }
            return unchanged(page.widget, owner: page, while: view) { $0.text == view.text }
        case "lumaChat" where engine != nil:
            return chatPage(UUID(uuidString: view.text ?? "")!, while: view)
        default:
            return unchanged(Self.textPage("\(view.viewName) views are not drawn yet."), while: view) { _ in true }
        }
    }

    private func unchanged(
        _ page: Widget,
        owner: AnyObject? = nil,
        while view: PharoViewDeclaration,
        _ same: @escaping (PharoViewDeclaration) -> Bool
    ) -> Shown {
        Shown(viewName: view.viewName, page: page, owner: owner, follows: same)
    }

    private func textViewPage(_ view: PharoViewDeclaration) -> Shown {
        let label = Self.textLabel(view.text ?? "")
        return Shown(viewName: view.viewName, page: Self.scrolledPage(label), owner: label) { [weak label] next in
            guard let label else { return false }
            label.setText(str: next.text ?? "")
            return true
        }
    }

    private func listPage(for view: PharoViewDeclaration) -> Shown {
        let list = PharoListView(source: source, view: view) { [weak self] element in
            self?.onDrill(element)
        }
        return Shown(viewName: view.viewName, page: list.widget, owner: list) { [weak list] next in
            guard let list, next.columns == view.columns else { return false }
            list.refresh()
            return true
        }
    }

    private func graphPage(_ graph: PharoGraph, selector: String) -> Shown {
        let area = PharoGraphArea(graph: graph)
        area.onDrill = { [weak self] index in
            guard let self else { return }
            Task { @MainActor in
                if let element = try? await self.source.drill(view: selector, index: index + 1, filter: nil) {
                    self.onDrill(element)
                }
            }
        }
        return Shown(viewName: "graph", page: area.widget, owner: area) { [weak area] next in
            guard let area, let graph = next.graph else { return false }
            area.show(graph)
            return true
        }
    }

    private func chartPage(_ chart: PharoChart, selector: String) -> Shown {
        let area = PharoChartArea(chart: chart)
        area.onDrill = { [weak self] index in
            guard let self else { return }
            Task { @MainActor in
                if let element = try? await self.source.drill(view: selector, index: index + 1, filter: nil) {
                    self.onDrill(element)
                }
            }
        }
        return Shown(viewName: "chart", page: area.widget, owner: area) { [weak area] next in
            guard let area, let chart = next.chart else { return false }
            area.show(chart)
            return true
        }
    }

    /// The scene is the host's already; the view only says which one, and the
    /// widget follows it as the image changes it.
    private func canvasPage(scene: Int) -> Shown {
        let canvas = PharoCanvasArea(scene: scene)
        return Shown(viewName: "canvas", page: canvas.widget, owner: canvas) { $0.canvas?.scene == scene }
    }

    private func bytesPage(_ bytes: PharoBytesReference, while view: PharoViewDeclaration) -> Shown {
        let hexView = HexView(bytes: bytes.data, baseAddress: bytes.address)
        hexView.widget.marginStart = 8
        hexView.widget.marginTop = 8
        let scroll = ScrolledWindow()
        scroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .automatic)
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: hexView.widget)
        return unchanged(scroll, owner: hexView, while: view) { $0.text == view.text }
    }

    private func patternBytesPage(_ target: PharoPatternTarget, while view: PharoViewDeclaration) -> Shown {
        let page = PharoPatternBytesPage(target: target)
        return unchanged(page.widget, owner: page, while: view) { $0.text == view.text }
    }

    private func patternVisualizationPage(_ target: PharoPatternTarget, while view: PharoViewDeclaration) -> Shown {
        let visualization: PatternVisualization
        do {
            visualization = try PatternVisualization(target.node.visualizer!, of: target.node, in: target.decoding.root)
        } catch {
            return unchanged(Self.failurePage(error.localizedDescription), while: view) { $0.text == view.text }
        }
        let widget = PatternVisualizationWidget(visualization)
        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: widget.widget)
        return unchanged(scroll, owner: widget, while: view) { $0.text == view.text }
    }

    private func chatPage(_ chatID: UUID, while view: PharoViewDeclaration) -> Shown {
        let page = PharoObjectChatPage(engine: engine!, chatID: chatID, form: .column) { [weak self] object in
            self?.onDrill(object)
        }
        page.onDiscarded = { [weak self] in self?.onClose() }
        return unchanged(page.widget, owner: page, while: view) { $0.text == view.text }
    }

    static func textPage(_ text: String) -> Box {
        scrolledPage(textLabel(text))
    }

    private static func textLabel(_ text: String) -> Label {
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
        return label
    }

    private static func scrolledPage(_ label: Label) -> Box {
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
