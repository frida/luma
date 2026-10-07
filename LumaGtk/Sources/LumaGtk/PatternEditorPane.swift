import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class PatternEditorPane {
    let widget: Overlay
    let sourceID: String
    var onCaretInType: (String?) -> Void = { _ in }

    private let engine: Engine
    private let editor: CodeEditor
    private let onError: (String) -> Void
    private var saveBar: SaveBar!
    private var draft: String
    private var savedText: String
    private var shownType: String??
    private var caretTypeLookup: Task<Void, Never>?

    init(engine: Engine, source: PatternSource, onError: @escaping (String) -> Void) {
        self.engine = engine
        self.sourceID = source.id
        self.onError = onError
        draft = source.text
        savedText = source.text
        editor = CodeEditor(engine: engine, profile: .pattern(source), initialText: source.text)

        widget = Overlay()
        widget.hexpand = true
        widget.vexpand = true
        widget.set(child: editor.widget)

        saveBar = SaveBar(saveTooltip: "Save pattern") { [weak self] in
            self?.save()
        }
        if source.origin == .project {
            widget.addOverlay(widget: saveBar.widget)
        }

        editor.onTextChanged = { [weak self] text in
            guard let self else { return }
            self.draft = text
            self.saveBar.setDirty(self.isDirty)
        }
        editor.onCaretMove = { [weak self] position in
            self?.followCaret(to: position)
        }
        observeSource()
    }

    func show(focusedType: String?) {
        guard shownType != .some(focusedType) else { return }
        shownType = focusedType
        if let focusedType {
            reveal(typeNamed: focusedType)
        } else {
            editor.focus()
        }
    }

    private func reveal(typeNamed name: String) {
        Task { @MainActor [weak self] in
            guard let self, let position = await self.declaration(of: name) else { return }
            self.editor.reveal(position)
            self.editor.focus()
        }
    }

    private func declaration(of typeName: String) async -> LSP.Position? {
        if let symbols = try? await editor.symbols() {
            return PatternSummary.declaration(of: typeName, in: symbols)
        }
        guard let summary = try? await engine.patternDecoder.summary(ofText: draft),
            let type = summary.types.first(where: { $0.name == typeName }), type.isDeclaredInSource
        else { return nil }
        return LSP.Position(line: type.line, character: type.character)
    }

    func flushDraftIfNeeded() {
        guard isDirty else { return }
        try? engine.patterns.write(draft, to: sourceID)
    }

    private func save() {
        do {
            try engine.patterns.write(draft, to: sourceID)
            savedText = draft
            saveBar.setDirty(false)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func followCaret(to position: LSP.Position) {
        caretTypeLookup?.cancel()
        let text = draft
        caretTypeLookup = Task { @MainActor [weak self] in
            guard let self, let symbols = try? await self.editor.symbols(),
                let summary = try? await self.engine.patternDecoder.summary(ofText: text),
                !Task.isCancelled
            else { return }
            let typeName = summary.declaredTypeName(at: position, in: symbols)
            guard self.shownType != .some(typeName) else { return }
            self.shownType = typeName
            self.onCaretInType(typeName)
        }
    }

    private func observeSource() {
        let stored = withObservationTracking {
            engine.patterns.source(withID: sourceID)?.text
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeSource()
            }
        }
        guard let stored, stored != savedText, !isDirty else { return }
        savedText = stored
        draft = stored
        editor.setText(stored)
    }

    private var isDirty: Bool {
        draft != savedText
    }
}
