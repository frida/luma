import CGtk
import Foundation
import Gdk
import Gtk
import GtkSource
import LumaCore
import SwiftyPharo

enum PharoRunMode {
    case doIt
    case printIt
    case inspect
}

/// The Smalltalk playground: a resizable page of snippet cards on the left and
/// the moldable inspector's columns on the right, drilling into what a snippet
/// produces. The page and its snippets are kept with the project.
@MainActor
final class PharoPlaygroundPane {
    let widget: Box

    private weak var engine: Engine?
    private let inspector: PharoColumnsView
    private let overviewBar = PharoOverviewBar()
    private let contentSeparator = Separator(orientation: .horizontal)
    private let paned: Paned
    private let inspectorOverlay = Overlay()
    private var maximizedChild: Widget?
    private let pageBox: Box

    private var snippets: [PharoPlaygroundSnippet]
    private var cards: [UUID: PharoSnippetCard] = [:]
    private var evaluating: Set<UUID> = []

    private let languageManager = GtkSource.LanguageManager()
    private let schemeManager = GtkSource.StyleSchemeManager()
    private var smalltalkLanguage: GtkSource.LanguageRef?
    private var lumaScheme: GtkSource.StyleSchemeRef?

    private let defaultPageWidth = 420

    init(engine: Engine) {
        self.engine = engine
        snippets = engine.pharoSnippets

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        pageBox = Box(orientation: .vertical, spacing: 12)
        pageBox.marginTop = 12
        pageBox.marginBottom = 12
        pageBox.marginStart = 12
        pageBox.marginEnd = 12

        let pageScroll = ScrolledWindow()
        pageScroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        pageScroll.hexpand = true
        pageScroll.vexpand = true
        pageScroll.set(child: pageBox)

        if let specs = Bundle.module.url(forResource: "smalltalk", withExtension: "lang", subdirectory: "pharo")?
            .deletingLastPathComponent().path {
            languageManager.appendSearchPath(path: specs)
            schemeManager.appendSearchPath(path: specs)
        }
        let language = languageManager.getLanguage(id: "smalltalk")
        let scheme = schemeManager.getScheme(schemeId: "luma")
        smalltalkLanguage = language
        lumaScheme = scheme

        inspector = PharoColumnsView(runtime: PharoRuntime.shared) { buffer in
            buffer.language = language
            buffer.styleScheme = scheme
            buffer.highlightSyntax = true
        }

        paned = Paned(orientation: .horizontal)
        paned.hexpand = true
        paned.vexpand = true
        paned.resizeStartChild = false
        paned.resizeEndChild = true
        paned.shrinkStartChild = false
        paned.shrinkEndChild = false
        paned.position = Int(engine.pharoPageWidth ?? Double(defaultPageWidth))
        paned.startChild = WidgetRef(pageScroll)
        paned.endChild = WidgetRef(inspector.widget)

        inspectorOverlay.hexpand = true
        inspectorOverlay.vexpand = true
        inspectorOverlay.set(child: paned)

        widget.append(child: overviewBar.widget)
        widget.append(child: contentSeparator)
        widget.append(child: inspectorOverlay)

        inspector.onMaximizeChanged = { [weak self] content in
            MainActor.assumeIsolated { self?.presentMaximized(content) }
        }

        paned.onNotifyPosition { [weak self] paned, _ in
            MainActor.assumeIsolated { self?.engine?.setPharoPageWidth(Double(paned.position)) }
        }

        configureOverviewBar()
        inspector.onChanged = { [weak self] in self?.overviewBar.reload() }
        inspector.contentAdjustment?.onValueChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.overviewBar.refresh() }
        }

        rebuildPage()
        refreshChrome()
    }

    /// A blown-up pane covers the page and the columns both, floating over the
    /// paned rather than filling only the inspector side.
    private func presentMaximized(_ content: Widget?) {
        if let existing = maximizedChild {
            inspectorOverlay.removeOverlay(widget: existing)
            maximizedChild = nil
        }
        guard let content else { return }

        let panel = Box(orientation: .vertical, spacing: 0)
        panel.add(cssClass: "luma-pharo-maximized")
        panel.hexpand = true
        panel.vexpand = true
        panel.halign = .fill
        panel.valign = .fill
        panel.marginTop = 8
        panel.marginBottom = 8
        panel.marginStart = 8
        panel.marginEnd = 8
        content.hexpand = true
        content.vexpand = true
        panel.append(child: content)

        inspectorOverlay.addOverlay(widget: panel)
        maximizedChild = panel
    }

    /// The strip stands over the whole page: a square for the snippets, then one
    /// per inspector column, with the current one drawn brightest.
    private func configureOverviewBar() {
        overviewBar.slotCount = { [weak self] in 1 + (self?.inspector.columnCount ?? 0) }
        overviewBar.isCurrent = { [weak self] slot in
            guard let self else { return false }
            return slot == 0 ? self.inspector.shownDepth == nil : self.inspector.shownDepth == slot - 1
        }
        overviewBar.tooltip = { [weak self] slot in
            guard let self else { return "" }
            return slot == 0 ? "Snippets" : self.inspector.printString(at: slot - 1)
        }
        overviewBar.activate = { [weak self] slot in
            guard let self else { return }
            if slot == 0 { self.inspector.focusPage() } else { self.inspector.reveal(depth: slot - 1) }
        }
        overviewBar.adjustment = { [weak self] in self?.inspector.contentAdjustment }
    }

    /// The page keeps its own resizable width whether or not anything is being
    /// inspected; the inspectors just sit empty beside it, no frame. The strip
    /// stands over the page while there are snippets, and an empty page clears
    /// any inspection so nothing lingers with nothing to open it.
    private func refreshChrome() {
        let hasSnippets = !snippets.isEmpty
        overviewBar.widget.visible = hasSnippets
        contentSeparator.visible = hasSnippets
        inspector.widget.visible = hasSnippets
        if !hasSnippets, !inspector.isEmpty {
            inspector.clearAll()
        }
        overviewBar.reload()
    }

    private func applyHighlighting(to buffer: GtkSource.Buffer) {
        buffer.language = smalltalkLanguage
        buffer.styleScheme = lumaScheme
        buffer.highlightSyntax = true
    }

    private func rebuildPage() {
        clear(pageBox)

        if snippets.isEmpty {
            pruneCards()
            pageBox.append(child: emptyState())
        } else {
            for snippet in snippets {
                let card = cards[snippet.id] ?? makeCard(for: snippet)
                cards[snippet.id] = card
                pageBox.append(child: card.widget)
            }
            pruneCards()
            pageBox.append(child: addSnippetButton())
        }
        refreshChrome()
    }

    private func pruneCards() {
        let live = Set(snippets.map(\.id))
        for id in cards.keys where !live.contains(id) {
            cards[id] = nil
        }
    }

    private func makeCard(for snippet: PharoPlaygroundSnippet) -> PharoSnippetCard {
        let id = snippet.id
        let card = PharoSnippetCard(
            id: id,
            source: snippet.source,
            highlight: { [weak self] buffer in self?.applyHighlighting(to: buffer) },
            completion: { [weak self] source, position in
                guard let self, let engine = self.engine else { return nil }
                try? await PharoRuntime.shared.startPlayground(for: engine)
                return try? await PharoRuntime.shared.completions(for: source, at: position)
            }
        )
        card.onRun = { [weak self] mode in self?.run(id, mode) }
        card.onFormat = { [weak self] in self?.format(id) }
        card.onBrowse = { [weak self] kind in self?.browse(id, kind) }
        card.onSourceChanged = { [weak self] source in self?.updateSource(id, source) }
        card.onMoveUp = { [weak self] in self?.moveUp(id) }
        card.onMoveDown = { [weak self] in self?.moveDown(id) }
        card.onDuplicate = { [weak self] in self?.duplicate(id) }
        card.onRemove = { [weak self] in self?.removeSnippet(id) }
        card.onAddToNotebook = { [weak self] in self?.addToNotebook(id) }
        return card
    }

    private func addSnippetButton() -> Button {
        let button = Button()
        button.add(cssClass: "flat")
        button.halign = .start
        let content = Box(orientation: .horizontal, spacing: 6)
        content.append(child: Image(iconName: "list-add-symbolic"))
        content.append(child: Label(str: "Add Snippet"))
        button.set(child: content)
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.addSnippet() }
        }
        return button
    }

    private func emptyState() -> Box {
        let box = Box(orientation: .vertical, spacing: 24)
        box.halign = .center
        box.valign = .center
        box.hexpand = true
        box.vexpand = true
        box.marginTop = 24
        box.marginBottom = 24
        box.marginStart = 24
        box.marginEnd = 24

        let header = Box(orientation: .vertical, spacing: 8)
        header.halign = .center

        let icon = Image(iconName: "utilities-terminal-symbolic")
        icon.pixelSize = 40
        icon.add(cssClass: "dim-label")

        let title = Label(str: "Playground")
        title.add(cssClass: "title-2")

        let subtitle = Label(str: "Slice, dice, and visualize your project's data with Pharo.")
        subtitle.add(cssClass: "dim-label")
        subtitle.wrap = true
        subtitle.justify = .center
        subtitle.maxWidthChars = 40

        header.append(child: icon)
        header.append(child: title)
        header.append(child: subtitle)

        let button = Button()
        button.add(cssClass: "suggested-action")
        button.add(cssClass: "pill")
        button.add(cssClass: "luma-fab")
        button.halign = .center
        let buttonContent = Box(orientation: .horizontal, spacing: 6)
        buttonContent.append(child: Image(iconName: "list-add-symbolic"))
        buttonContent.append(child: Label(str: "New Snippet"))
        button.set(child: buttonContent)
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.addSnippet() }
        }

        box.append(child: header)
        box.append(child: tips())
        box.append(child: button)
        return box
    }

    private func tips() -> Box {
        let lines = [
            "Write an expression and run it to inspect what it makes; double-click a row to drill in.",
            "Paint graphs and charts, or script your own views of the result.",
            "Reach the project itself with LumaProject events and LumaProject sessions.",
        ]

        let list = Box(orientation: .vertical, spacing: 8)
        list.halign = .center
        for (index, text) in lines.enumerated() {
            let row = Box(orientation: .horizontal, spacing: 8)
            row.valign = .start

            let number = Label(str: "\(index + 1).")
            number.add(cssClass: "dim-label")
            number.add(cssClass: "monospace")
            number.xalign = 1
            number.valign = .start
            number.setSizeRequest(width: 18, height: -1)

            let body = Label(str: text)
            body.wrap = true
            body.xalign = 0
            body.maxWidthChars = 52

            row.append(child: number)
            row.append(child: body)
            list.append(child: row)
        }
        return list
    }

    private func addSnippet() {
        let added = PharoPlaygroundSnippet(source: "")
        snippets.append(added)
        persist()
        rebuildPage()
        cards[added.id]?.focusEditor()
    }

    private func duplicate(_ id: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        let copy = PharoPlaygroundSnippet(source: snippets[index].source)
        snippets.insert(copy, at: index + 1)
        persist()
        rebuildPage()
        cards[copy.id]?.focusEditor()
    }

    private func removeSnippet(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        persist()
        rebuildPage()
    }

    private func moveUp(_ id: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }), index > 0 else { return }
        snippets.swapAt(index, index - 1)
        persist()
        rebuildPage()
    }

    private func moveDown(_ id: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }), index < snippets.count - 1 else { return }
        snippets.swapAt(index, index + 1)
        persist()
        rebuildPage()
    }

    private func updateSource(_ id: UUID, _ source: String) {
        guard let index = snippets.firstIndex(where: { $0.id == id }), snippets[index].source != source else { return }
        snippets[index].source = source
        persist()
    }

    private func persist() {
        engine?.setPharoSnippets(snippets)
    }

    private func run(_ id: UUID, _ mode: PharoRunMode) {
        guard let engine, let card = cards[id], !evaluating.contains(id) else { return }
        let source = card.source
        guard !source.isEmpty else { return }
        evaluating.insert(id)

        Task { @MainActor in
            defer { evaluating.remove(id) }
            do {
                try await PharoRuntime.shared.startPlayground(for: engine)
                let produced = try await PharoRuntime.shared.evaluate(source)
                cards[id]?.flashOutcome(success: true)
                switch mode {
                case .doIt:
                    cards[id]?.showResult(nil, isError: false)
                case .printIt:
                    cards[id]?.showResult(produced.printString, isError: false)
                case .inspect:
                    cards[id]?.showResult(nil, isError: false)
                    inspector.present(produced)
                    if let card = cards[id] {
                        inspector.pointArrow(fromCenterOf: WidgetRef(card.widget))
                    }
                }
            } catch {
                cards[id]?.flashOutcome(success: false)
                cards[id]?.showResult(error.localizedDescription, isError: true)
            }
        }
    }

    /// Keeps a snippet's code and what its last run made in the notebook, the
    /// eager snapshot standing in for the result so it reads back with no VM.
    private func addToNotebook(_ id: UUID) {
        guard let engine, let card = cards[id] else { return }
        let source = card.source
        guard !source.isEmpty else { return }

        Task { @MainActor in
            do {
                try await PharoRuntime.shared.startPlayground(for: engine)
                let produced = try await PharoRuntime.shared.evaluate(source)
                let snapshot = try await PharoSnapshot.capture(of: produced, using: PharoRuntime.shared)
                let entry = NotebookEntry(kind: .pharo, title: "", details: source, pharoSnapshot: snapshot)
                engine.addNotebookEntry(entry)
                card.flashOutcome(success: true)
            } catch {
                card.flashOutcome(success: false)
                card.showResult(error.localizedDescription, isError: true)
            }
        }
    }

    private func format(_ id: UUID) {
        guard let engine, let card = cards[id] else { return }
        let source = card.source
        guard !source.isEmpty else { return }
        Task { @MainActor in
            try? await PharoRuntime.shared.startPlayground(for: engine)
            if let formatted = try? await PharoRuntime.shared.format(source: source), formatted != card.source {
                card.setSource(formatted)
                updateSource(id, formatted)
            }
        }
    }

    private func browse(_ id: UUID, _ kind: PharoBrowseKind) {
        guard let engine, let card = cards[id] else { return }
        let source = card.source
        guard !source.isEmpty else { return }
        let position = card.cursorOffset()
        Task { @MainActor in
            do {
                try await PharoRuntime.shared.startPlayground(for: engine)
                let found = try await PharoRuntime.shared.browse(kind, source: source, at: position)
                if let result = found.result {
                    cards[id]?.showResult(nil, isError: false)
                    inspector.present(result)
                } else {
                    cards[id]?.showResult("No \(kind.rawValue) for the selector at the cursor.", isError: true)
                }
            } catch {
                cards[id]?.showResult(error.localizedDescription, isError: true)
            }
        }
    }

    private func clear(_ box: Box) {
        while let existing = box.getFirstChild() {
            box.remove(child: existing)
        }
    }
}
