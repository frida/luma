import CGtk
import Foundation
import Gtk
import LumaCore
import Observation
import SwiftyPharo

@MainActor
final class InstrumentViewWidget {
    let widget: Box

    private weak var engine: Engine?
    private let key: InstrumentViews.Key
    private let page: Box
    private let inspector: PharoColumnsView
    private let overviewBar = PharoOverviewBar()
    private let overviewSeparator = Separator(orientation: .horizontal)
    private var shown: InstrumentViews.Phase?
    private var pages: PharoViewPages?
    private var selectors: [String] = []
    private var notebook: Notebook?
    private var keptTab: String?
    private var spawnedInspections: Task<Void, Never>?
    private let drilledPageWidth = 420

    init(engine: Engine, key: InstrumentViews.Key, sessionID: UUID, name: String, config: InstrumentWidget.ViewConfig) {
        self.engine = engine
        self.key = key

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true

        page = Box(orientation: .vertical, spacing: 0)
        page.hexpand = true
        page.vexpand = true

        let overlay = Overlay()
        overlay.vexpand = true
        overlay.setSizeRequest(width: -1, height: config.height)
        inspector = PharoColumnsView(
            engine: engine, runtime: PharoRuntime.shared, maximizingOver: overlay, highlight: PharoHighlighting.apply)
        inspector.widget.visible = false
        inspector.chatOrigin = {
            PharoChatOrigin(
                origin: .instrumentView(instanceID: key.instanceID, widget: key.widget, sessionID: sessionID),
                label: "the \(name) view of an instrument",
                source: nil)
        }

        let paned = Paned(orientation: .horizontal)
        paned.resizeStartChild = false
        paned.resizeEndChild = true
        paned.shrinkStartChild = false
        paned.shrinkEndChild = false
        paned.position = drilledPageWidth
        paned.startChild = WidgetRef(page)
        paned.endChild = WidgetRef(inspector.widget)
        overlay.set(child: paned)
        overviewBar.widget.visible = false
        overviewSeparator.visible = false
        widget.append(child: overviewBar.widget)
        widget.append(child: overviewSeparator)
        widget.append(child: overlay)

        inspector.drive(overviewBar) { name }
        inspector.onChanged = { [weak self] in
            guard let self else { return }
            let isDrilling = !self.inspector.isEmpty
            self.inspector.widget.visible = isDrilling
            self.overviewBar.widget.visible = isDrilling
            self.overviewSeparator.visible = isDrilling
            self.overviewBar.reload()
        }
        widget.onMap { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine?.instrumentViews.show(self.key)
                self.inspectSpawned()
            }
        }
        widget.onUnmap { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine?.instrumentViews.hide(self.key)
                self.spawnedInspections?.cancel()
            }
        }
        follow()
    }

    private func inspectSpawned() {
        guard let spawned = engine?.instrumentViews.spawns(of: key) else { return }
        spawnedInspections = Task { @MainActor [weak self] in
            for await object in spawned {
                self?.inspect(object)
            }
        }
    }

    private func follow() {
        guard let views = engine?.instrumentViews else { return }
        let state = withObservationTracking { () -> (phase: InstrumentViews.Phase, gated: Bool) in
            (views.phase(of: key), views.approvalWanted(byInstance: key.instanceID) != nil)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        guard !state.gated else { return showNothing() }
        guard state.phase != shown else { return }
        shown = state.phase
        show(state.phase)
    }

    private func showNothing() {
        shown = nil
        pages = nil
        while let child = page.firstChild {
            page.remove(child: child)
        }
    }

    private func show(_ phase: InstrumentViews.Phase) {
        if case .running = phase, let pages {
            return refresh(pages)
        }
        while let child = page.firstChild {
            page.remove(child: child)
        }
        pages = nil
        switch phase {
        case .idle, .checking, .starting:
            let spinner = makeSpinner()
            spinner.halign = .center
            spinner.valign = .center
            spinner.vexpand = true
            page.append(child: spinner)
        case .failed(let message):
            page.append(child: stopped(message))
        case .running:
            load()
        default:
            break
        }
    }

    private func refresh(_ pages: PharoViewPages) {
        guard let engine else { return }
        let source = InstrumentViewSource(instrumentViews: engine.instrumentViews, key: key)
        Task { @MainActor [weak self] in
            let declarations = try? await source.views()
            guard let self, self.pages === pages else { return }
            guard let declarations, declarations.map(\.methodSelector) == self.selectors else {
                return self.rebuild()
            }
            for (index, declaration) in declarations.enumerated() {
                let (page, replacing) = pages.refreshed(declaration)
                guard let replacing else { continue }
                page.vexpand = true
                self.swap(replacing, for: page, at: index, titled: declaration.title)
            }
        }
    }

    private func rebuild() {
        keptTab = notebook.map { selectors[$0.currentPage] }
        pages = nil
        if let shown {
            show(shown)
        }
    }

    private func swap(_ old: Widget, for new: Widget, at index: Int, titled title: String) {
        guard let notebook else {
            page.remove(child: old)
            page.append(child: new)
            return
        }
        let current = notebook.currentPage
        notebook.removePage(pageNum: index)
        _ = notebook.insertPage(child: new, tabLabel: Label(str: title), position: index)
        notebook.currentPage = current
    }

    private func stopped(_ message: String) -> Widget {
        let box = Box(orientation: .vertical, spacing: 8)
        box.vexpand = true
        box.marginStart = 12
        box.marginEnd = 12
        box.marginTop = 12
        box.marginBottom = 12

        let title = Label(str: InstrumentViews.stoppedTitle)
        title.add(cssClass: "heading")
        title.add(cssClass: "error")
        title.halign = .start
        box.append(child: title)

        let detail = PharoViewPages.failurePage(message)
        detail.vexpand = true
        box.append(child: detail)

        let restart = Button(label: InstrumentViews.restartLabel)
        restart.halign = .start
        restart.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine?.instrumentViews.restart(self.key)
            }
        }
        box.append(child: restart)
        return box
    }

    private func load() {
        guard let engine else { return }
        let source = InstrumentViewSource(instrumentViews: engine.instrumentViews, key: key)
        let pages = PharoViewPages(source: source, runtime: PharoRuntime.shared, engine: engine) { [weak self] object in
            self?.inspect(object)
        }
        self.pages = pages
        Task { @MainActor [weak self] in
            let declarations: [PharoViewDeclaration]
            do {
                declarations = try await source.views()
            } catch {
                self?.page.append(child: PharoViewPages.failurePage(error.localizedDescription))
                return
            }
            guard let self, self.pages === pages else { return }
            self.selectors = declarations.map(\.methodSelector)
            self.notebook = nil
            guard declarations.count > 1 else {
                if let only = declarations.first {
                    let page = pages.page(for: only)
                    page.vexpand = true
                    self.page.append(child: page)
                }
                return
            }
            let notebook = Notebook()
            notebook.vexpand = true
            notebook.scrollable = true
            for declaration in declarations {
                _ = notebook.appendPage(child: pages.page(for: declaration), tabLabel: Label(str: declaration.title))
            }
            if let kept = declarations.firstIndex(where: { $0.methodSelector == self.keptTab }) {
                notebook.currentPage = kept
            }
            self.keptTab = nil
            self.notebook = notebook
            self.page.append(child: notebook)
        }
    }

    private func inspect(_ object: PharoObject) {
        inspector.present(object)
        inspector.pointArrow(fromCenterOf: WidgetRef(page))
    }
}
