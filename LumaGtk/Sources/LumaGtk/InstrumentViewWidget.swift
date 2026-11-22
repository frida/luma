import Adw
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
    private var shown: InstrumentViews.Phase?
    private var pages: PharoViewPages?
    private var inspectors: [ObjectIdentifier: PharoColumnView] = [:]

    init(engine: Engine, key: InstrumentViews.Key, config: InstrumentWidget.ViewConfig) {
        self.engine = engine
        self.key = key

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.setSizeRequest(width: -1, height: config.height)
        widget.onMap { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine?.instrumentViews.show(self.key)
            }
        }
        widget.onUnmap { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine?.instrumentViews.hide(self.key)
            }
        }
        follow()
    }

    private func follow() {
        guard let views = engine?.instrumentViews else { return }
        let phase = withObservationTracking {
            views.phase(of: key)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        guard phase != shown else { return }
        shown = phase
        show(phase)
    }

    private func show(_ phase: InstrumentViews.Phase) {
        while let child = widget.firstChild {
            widget.remove(child: child)
        }
        pages = nil
        switch phase {
        case .idle, .checking, .starting:
            let spinner = makeSpinner()
            spinner.halign = .center
            spinner.valign = .center
            spinner.vexpand = true
            widget.append(child: spinner)
        case .awaitingApproval(let origin):
            widget.append(child: approval(origin))
        case .failed(let message):
            widget.append(child: stopped(message))
        case .running:
            load()
        }
    }

    private func approval(_ origin: HostCodeOrigin) -> Widget {
        let page = Adw.StatusPage()
        page.iconName = "security-medium-symbolic"
        page.title = HostCodeOrigin.request
        page.description = origin.provenance
        page.vexpand = true
        let allow = Button(label: HostCodeOrigin.allowLabel)
        allow.add(cssClass: "suggested-action")
        allow.add(cssClass: "pill")
        allow.halign = .center
        allow.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine?.instrumentViews.allow(self.key)
            }
        }
        page.set(child: allow)
        return page
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
        guard let views = engine?.instrumentViews else { return }
        let source = InstrumentViewSource(instrumentViews: views, key: key)
        let pages = PharoViewPages(source: source) { [weak self] object in
            self?.inspect(object)
        }
        self.pages = pages
        Task { @MainActor [weak self] in
            let declarations: [PharoViewDeclaration]
            do {
                declarations = try await source.views()
            } catch {
                self?.widget.append(child: PharoViewPages.failurePage(error.localizedDescription))
                return
            }
            guard let self, self.pages === pages else { return }
            guard declarations.count > 1 else {
                if let only = declarations.first {
                    let page = pages.page(for: only)
                    page.vexpand = true
                    self.widget.append(child: page)
                }
                return
            }
            let notebook = Notebook()
            notebook.vexpand = true
            notebook.scrollable = true
            for declaration in declarations {
                _ = notebook.appendPage(child: pages.page(for: declaration), tabLabel: Label(str: declaration.title))
            }
            self.widget.append(child: notebook)
        }
    }

    private func inspect(_ object: PharoObject) {
        let column = PharoColumnView(
            runtime: PharoRuntime.shared, object: object, isMaximized: true, highlight: PharoHighlighting.apply)
        column.offersLayoutActions = false

        let window = Adw.Window()
        window.title = object.className
        window.setDefaultSize(width: 520, height: 480)
        window.destroyWithParent = true
        if let rootPtr = widget.root?.ptr {
            window.setTransientFor(parent: Gtk.WindowRef(raw: rootPtr))
        }
        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: Adw.HeaderBar())
        toolbarView.set(content: column.widget)
        window.set(content: toolbarView)
        column.onDrill = { [weak self] element in self?.inspect(element) }
        column.onClose = { window.close() }
        let id = ObjectIdentifier(window)
        inspectors[id] = column
        window.onCloseRequest { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.inspectors.removeValue(forKey: id)
            }
            return false
        }
        installEscapeShortcut(on: window)
        window.present()
    }
}
