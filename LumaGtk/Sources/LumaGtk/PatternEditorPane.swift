import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class PatternEditorPane {
    let widget: Overlay
    let sourceID: String

    private let engine: Engine
    private let editor: CodeEditor
    private let onError: (String) -> Void
    private var saveBar: SaveBar!
    private var draft: String
    private var savedText: String
    private var shownType: String??

    init(engine: Engine, source: PatternSource, onError: @escaping (String) -> Void) {
        self.engine = engine
        self.sourceID = source.id
        self.onError = onError
        draft = source.text
        savedText = source.text
        editor = CodeEditor(engine: engine, profile: .pattern(activePath: "Patterns/" + source.id), initialText: source.text)

        widget = Overlay()
        widget.hexpand = true
        widget.vexpand = true
        widget.set(child: editor.widget)

        saveBar = SaveBar(saveTooltip: "Save pattern") { [weak self] in
            self?.save()
        }
        widget.addOverlay(widget: saveBar.widget)

        editor.onTextChanged = { [weak self] text in
            guard let self else { return }
            self.draft = text
            self.saveBar.setDirty(self.isDirty)
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
        let text = draft
        Task { @MainActor [weak self] in
            guard let self, let summary = try? await self.engine.patternDecoder.summary(ofText: text),
                let type = summary.types.first(where: { $0.name == name }), type.isDeclaredInSource
            else { return }
            self.editor.reveal(LSP.Position(line: type.line, character: type.character))
            self.editor.focus()
        }
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
