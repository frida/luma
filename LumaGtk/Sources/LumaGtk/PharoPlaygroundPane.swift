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
    private let paned: Paned
    private let pageBox: Box

    private var snippets: [PharoPlaygroundSnippet]
    private var cards: [UUID: PharoSnippetCard] = [:]
    private var liveResults: [UUID: PharoObject] = [:]
    private var evaluating: Set<UUID> = []

    private var smalltalkLanguage: GtkSource.LanguageRef?
    private var lumaScheme: GtkSource.StyleSchemeRef?

    private let defaultPageWidth = 420

    init(engine: Engine) {
        self.engine = engine
        snippets = engine.pharoSnippets

        widget = Box(orientation: .horizontal, spacing: 0)
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

        inspector = PharoColumnsView(runtime: PharoRuntime.shared)

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
        widget.append(child: paned)

        paned.onNotifyPosition { [weak self] paned, _ in
            MainActor.assumeIsolated { self?.engine?.setPharoPageWidth(Double(paned.position)) }
        }

        resolveHighlighting()
        rebuildPage()
        inspector.showMessage("Evaluate a snippet with Ctrl+Return to open its result here.")
    }

    private func resolveHighlighting() {
        guard let specs = Bundle.module.url(forResource: "smalltalk", withExtension: "lang", subdirectory: "pharo")?
            .deletingLastPathComponent().path
        else { return }

        let languages = GtkSource.LanguageManager()
        let schemes = GtkSource.StyleSchemeManager()
        languages.appendSearchPath(path: specs)
        schemes.appendSearchPath(path: specs)
        smalltalkLanguage = languages.getLanguage(id: "smalltalk")
        lumaScheme = schemes.getScheme(schemeId: "luma")
    }

    private func applyHighlighting(to buffer: GtkSource.Buffer) {
        buffer.language = smalltalkLanguage
        buffer.styleScheme = lumaScheme
        buffer.highlightSyntax = true
    }

    private func rebuildPage() {
        clear(pageBox)

        guard !snippets.isEmpty else {
            pruneCards()
            pageBox.append(child: emptyState())
            return
        }

        for snippet in snippets {
            let card = cards[snippet.id] ?? makeCard(for: snippet)
            cards[snippet.id] = card
            pageBox.append(child: card.widget)
        }
        pruneCards()
        pageBox.append(child: addSnippetButton())
    }

    private func pruneCards() {
        let live = Set(snippets.map(\.id))
        for id in cards.keys where !live.contains(id) {
            cards[id] = nil
            liveResults[id] = nil
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
        card.onReopenResult = { [weak self] in self?.reopen(id) }
        card.onMoveUp = { [weak self] in self?.moveUp(id) }
        card.onMoveDown = { [weak self] in self?.moveDown(id) }
        card.onDuplicate = { [weak self] in self?.duplicate(id) }
        card.onRemove = { [weak self] in self?.removeSnippet(id) }
        card.setResultAvailable(liveResults[id] != nil)
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
        let box = Box(orientation: .vertical, spacing: 16)
        box.halign = .center
        box.valign = .center
        box.hexpand = true
        box.vexpand = true
        box.marginTop = 48
        box.marginStart = 24
        box.marginEnd = 24

        let icon = Image(iconName: "utilities-terminal-symbolic")
        icon.pixelSize = 48
        icon.add(cssClass: "dim-label")

        let title = Label(str: "Playground")
        title.add(cssClass: "title-2")

        let subtitle = Label(str: "Slice, dice, and visualize your project's data with Pharo.")
        subtitle.add(cssClass: "dim-label")
        subtitle.wrap = true
        subtitle.justify = .center
        subtitle.maxWidthChars = 32

        let button = Button(label: "New Snippet")
        button.add(cssClass: "suggested-action")
        button.add(cssClass: "pill")
        button.halign = .center
        button.marginTop = 8
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.addSnippet() }
        }

        box.append(child: icon)
        box.append(child: title)
        box.append(child: subtitle)
        box.append(child: button)
        return box
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
        inspector.showMessage("Evaluating…")

        Task { @MainActor in
            defer { evaluating.remove(id) }
            do {
                try await PharoRuntime.shared.startPlayground(for: engine)
                let produced = try await PharoRuntime.shared.evaluate(source)
                liveResults[id] = produced
                cards[id]?.setResultAvailable(true)
                switch mode {
                case .doIt:
                    inspector.showMessage("Done.")
                case .printIt:
                    inspector.showMessage(produced.printString)
                case .inspect:
                    inspector.present(produced)
                }
            } catch {
                inspector.showMessage(error.localizedDescription)
            }
        }
    }

    private func reopen(_ id: UUID) {
        guard let object = liveResults[id] else { return }
        inspector.present(object)
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
        inspector.showMessage("Browsing \(kind.rawValue)…")
        Task { @MainActor in
            do {
                try await PharoRuntime.shared.startPlayground(for: engine)
                let found = try await PharoRuntime.shared.browse(kind, source: source, at: position)
                if let result = found.result {
                    inspector.present(result)
                } else {
                    inspector.showMessage("No \(kind.rawValue) for the selector at the cursor.")
                }
            } catch {
                inspector.showMessage(error.localizedDescription)
            }
        }
    }

    private func clear(_ box: Box) {
        while let existing = box.getFirstChild() {
            box.remove(child: existing)
        }
    }
}
