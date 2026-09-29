import LumaCore
import SwiftUI

struct PatternEditorView: View {
    let sourceID: String
    let focusedType: String?
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var reveal: EditorReveal?

    @State private var draft: String
    @State private var isDirty = false
    @State private var showSavedCheck = false
    @State private var isEditorFocused = false
    @State private var errorMessage: String?

    init(sourceID: String, focusedType: String?, engine: Engine, selection: Binding<SidebarItemID?>) {
        self.sourceID = sourceID
        self.focusedType = focusedType
        self.engine = engine
        _selection = selection
        _draft = State(initialValue: engine.patterns.source(withID: sourceID)?.text ?? "")
    }

    private var source: PatternSource? {
        engine.patterns.source(withID: sourceID)
    }

    var body: some View {
        Group {
            if let source {
                content(source)
            } else {
                Text("Pattern not found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .alert("Pattern library error", isPresented: errorBinding, presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func content(_ source: PatternSource) -> some View {
        ZStack(alignment: .topTrailing) {
            CodeEditorView(
                text: $draft,
                profile: .pattern(activePath: "Patterns/" + source.id),
                focused: $isEditorFocused,
                reveal: reveal,
                engine: engine
            )
            .accessibilityIdentifier("pattern.editor")

            SaveBarOverlay(
                isDirty: isDirty,
                showSavedCheck: showSavedCheck,
                saveTooltip: "Save (\u{2318}S)",
                onSave: save
            )
        }
        .padding(.top, 8)
        .padding(.leading, 8)
        .padding(.bottom, 8)
        .onAppear {
            isEditorFocused = focusedType == nil
        }
        .onChange(of: source.text) { _, newValue in
            if !isDirty { draft = newValue }
        }
        .onChange(of: draft) { _, newValue in
            isDirty = newValue != source.text
        }
        .task(id: focusedType) {
            await revealFocusedType()
        }
        .onDisappear { flushIfNeeded() }
    }

    private func revealFocusedType() async {
        guard let focusedType,
            let summary = try? await engine.patternDecoder.summary(ofText: draft),
            let type = summary.types.first(where: { $0.name == focusedType }), type.isDeclaredInSource
        else { return }
        let name = LSP.Position(line: type.line, character: type.character)
        reveal = EditorReveal(range: LSP.Range(start: name, end: name), generation: (reveal?.generation ?? 0) + 1)
    }

    private func save() {
        do {
            try engine.patterns.write(draft, to: sourceID)
            isDirty = false
            showSavedCheck = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                withAnimation { showSavedCheck = false }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func flushIfNeeded() {
        guard isDirty, source != nil else { return }
        try? engine.patterns.write(draft, to: sourceID)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
