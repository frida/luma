import Frida
import SwiftUI
import LumaCore

extension LumaCore.REPLLanguage {
    var promptGlyph: String {
        switch self {
        case .javascript: return "\u{203A}"
        case .r2: return "\u{00BB}"
        }
    }

    var promptColor: Color {
        switch self {
        case .javascript: return .orange
        case .r2: return .blue
        }
    }

    var inputPlaceholder: String {
        switch self {
        case .javascript: return "Enter JavaScript\u{2026}"
        case .r2: return "Enter an r2 command\u{2026}"
        }
    }
}

struct REPLView: View {
    let sessionID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var inputCode: String = ""
    @State private var isInputFocused: Bool = false
    @State private var mode: LumaCore.REPLLanguage = .javascript
    @State private var didRestoreInputState = false
    @State private var draftSaveTask: Task<Void, Never>?

    @State private var historyCursor: Int = 0
    @State private var historyCursorInitialized = false

    @State private var cells: [LumaCore.REPLCell] = []
    @State private var cellsObservation: StoreObservation?

    private var session: LumaCore.ProcessSession? {
        engine.sessions.first { $0.id == sessionID }
    }

    private var node: LumaCore.ProcessNode? {
        engine.node(forSessionID: sessionID)
    }

    private var canSubmit: Bool {
        canInteract && hasLiveTarget
    }

    private var canInteract: Bool {
        !engine.collaboration.isCollaborative || engine.collaboration.isOwner
    }

    private var hasLiveTarget: Bool {
        if engine.isHostingNode(sessionID) { return true }
        guard let session,
              let host = session.host,
              host.id != engine.localUserID
        else { return false }
        return session.phase == .attached || session.phase == .attaching
    }

    private var orderedCells: [LumaCore.REPLCell] {
        cells.sorted { $0.timestamp < $1.timestamp }
    }

    private var commandHistory: [LumaCore.REPLCell] {
        orderedCells.filter { !$0.isSessionBoundary }
    }

    private var replInactiveMessage: String {
        guard let session else { return "Session not attached." }
        if case .armed = session.armingState {
            if engine.isGatingActive(forDeviceID: session.deviceID) {
                return "Waiting for a matching launch — REPL available once captured."
            }
            return "Armed but inactive — resume spawn gating to capture launches."
        }
        if let host = session.host,
           host.id != engine.localUserID,
           engine.node(forSessionID: session.id) == nil,
           session.phase == .attached || session.phase == .attaching
        {
            return "Hosted by @\(host.id) on \(session.deviceName) — REPL runs on the hosting device."
        }
        if session.lastAttachedAt != nil {
            return "Session detached — use \(session.kind.reestablishLabel) to continue."
        }
        switch session.kind {
        case .spawn:
            return "Session not attached — arm it from the banner above."
        case .attach:
            return "Session not attached — use \(session.kind.reestablishLabel) from the banner above."
        }
    }

    private var replInactiveHelp: String {
        guard let session else { return "Session not attached." }
        if case .armed = session.armingState {
            if engine.isGatingActive(forDeviceID: session.deviceID) {
                return "REPL becomes available after the next matching launch is captured."
            }
            return "Spawn gating is paused — resume it from the banner above."
        }
        if session.lastAttachedAt != nil {
            return "Detached — re-establish this session before running commands."
        }
        switch session.kind {
        case .spawn:
            return "Arm this session to capture the next matching launch."
        case .attach:
            return "Re-attach this session to the target process."
        }
    }

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var horizontalInset: CGFloat { horizontalSizeClass == .compact ? 6 : 16 }
    #else
    private var horizontalInset: CGFloat { 16 }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { outerGeo in
                if orderedCells.isEmpty {
                    REPLEmptyState()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, horizontalInset)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(orderedCells) { cell in
                                    REPLCellView(
                                        cell: cell,
                                        processName: session?.processName ?? "",
                                        sessionID: sessionID,
                                        engine: engine,
                                        selection: $selection
                                    )
                                    .id(cell.id)
                                }
                            }
                            .frame(
                                maxWidth: .infinity,
                                minHeight: outerGeo.size.height,
                                alignment: .bottomLeading
                            )
                            .padding(.horizontal, horizontalInset)

                            Color.clear
                                .frame(height: 2)
                                .id("repl-bottom-anchor")
                        }
                        .onAppear {
                            reloadCells()
                            scrollToBottom(proxy: proxy)
                        }
                        .onChange(of: cells.count) {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Button {
                    toggleMode()
                } label: {
                    Text(mode.promptGlyph)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(mode.promptColor)
                }
                .buttonStyle(.plain)
                .help("Switch between JavaScript and r2 input — or type “:” to toggle")

                if canSubmit {
                    REPLInputField(
                        text: $inputCode,
                        isFocused: $isInputFocused,
                        onCommit: { cmd in
                            runCurrentInput(cmd)
                        },
                        onHistoryUp: {
                            historyPrevious()
                        },
                        onHistoryDown: {
                            historyNext()
                        },
                        requestCompletions: { code, cursor in
                            guard let node = engine.node(forSessionID: sessionID) else { return [] as [LumaCore.REPLCompletion] }
                            return await node.completeInREPL(code: code, cursor: cursor, language: mode)
                        },
                        language: mode,
                        placeholder: mode.inputPlaceholder
                    )
                    .frame(minHeight: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("repl.input")
                } else {
                    ZStack(alignment: .leading) {
                        REPLInputField(
                            text: .constant(""),
                            isFocused: .constant(false),
                            onCommit: { _ in },
                            onHistoryUp: {},
                            onHistoryDown: {},
                            requestCompletions: { _, _ in [] as [LumaCore.REPLCompletion] },
                            language: .javascript,
                            placeholder: ""
                        )
                        .disabled(true)
                        .opacity(0.35)
                        .frame(minHeight: 22)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(replInactiveMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                    .help(replInactiveHelp)
                }

                Button {
                    runCurrentInput()
                } label: {
                    Image(systemName: "return")
                }
                .buttonStyle(.borderless)
                .help("Run")
                .disabled(!canSubmit)
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onAppear {
            if cellsObservation == nil {
                cellsObservation = engine.store.observeREPLCells(sessionID: sessionID) { [self] newCells in
                    Task { @MainActor in
                        self.cells = newCells
                    }
                }
            }

            if !didRestoreInputState {
                didRestoreInputState = true
                inputCode = engine.replDraft(forSessionID: sessionID) ?? ""
                mode = engine.replLanguage(forSessionID: sessionID)
            }

            DispatchQueue.main.async {
                isInputFocused = node != nil

                if !historyCursorInitialized {
                    historyCursor = commandHistory.count
                    historyCursorInitialized = true
                }
            }
        }
        .onChange(of: inputCode) {
            scheduleDraftSave()
        }
        .onChange(of: mode) { _, newValue in
            engine.setREPLLanguage(sessionID: sessionID, newValue)
        }
        .contextMenu {
            Button {
                clearHistory()
            } label: {
                Label("Clear History", systemImage: "trash")
            }
        }
    }

    private func reloadCells() {
        cells = (try? engine.store.fetchREPLCells(sessionID: sessionID)) ?? []
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo("repl-bottom-anchor", anchor: .bottom)
        }
    }

    private func clearHistory() {
        cells.removeAll()
        historyCursor = 0
    }

    private func runCurrentInput(_ provided: String? = nil) {
        let raw = provided ?? inputCode
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        inputCode = ""

        guard !code.isEmpty else {
            isInputFocused = true
            return
        }

        if let switched = modeCommand(code) {
            mode = switched
            isInputFocused = true
            return
        }

        if engine.isHostedRemotelyLive(sessionID) {
            let cellID = UUID()
            let placeholder = LumaCore.REPLCell(
                id: cellID,
                sessionID: sessionID,
                code: code,
                language: mode,
                result: .text("Running…"),
                timestamp: Date()
            )
            try? engine.store.save(placeholder)
            engine.collaboration.sendReplEvalRequest(
                sessionID: sessionID,
                code: code,
                language: mode,
                cellID: cellID
            )
            reloadCells()
            historyCursor = commandHistory.count
        } else if let node {
            Task { @MainActor in
                await node.evalInREPL(code, language: mode)
                reloadCells()
                historyCursor = commandHistory.count
            }
        }

        isInputFocused = true
    }

    private func toggleMode() {
        mode = mode == .javascript ? .r2 : .javascript
        isInputFocused = true
    }

    private func modeCommand(_ code: String) -> LumaCore.REPLLanguage? {
        switch code {
        case ":": return mode == .javascript ? .r2 : .javascript
        case ":js", ":javascript": return .javascript
        case ":r2": return .r2
        default: return nil
        }
    }

    private func historyPrevious() {
        let history = commandHistory
        guard !history.isEmpty else {
            return
        }

        if historyCursor != 0 {
            historyCursor -= 1
        }

        recall(history[historyCursor])
    }

    private func historyNext() {
        let history = commandHistory
        guard !history.isEmpty else {
            return
        }

        if historyCursor < history.count - 1 {
            historyCursor += 1
            recall(history[historyCursor])
        } else {
            historyCursor = history.count
            inputCode = ""
        }
    }

    private func recall(_ cell: LumaCore.REPLCell) {
        inputCode = cell.code
        mode = cell.language
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        let draft = inputCode
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            engine.setREPLDraft(sessionID: sessionID, draft.isEmpty ? nil : draft)
        }
    }
}

private struct REPLEmptyState: View {
    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer(minLength: 0)

                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)

                        Text("Read-Eval-Print Loop")
                            .font(.title2.weight(.semibold))

                        Text("Evaluate JavaScript in the target process.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    tips
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            tip("Type an expression and press Return to evaluate it.")
            tip("Step through previous expressions with ↑ and ↓.")
            tip("Try Process.mainModule.base.readByteArray(64).")
        }
        .font(.callout)
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct REPLCellView: View {
    let cell: LumaCore.REPLCell
    let processName: String
    let sessionID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?

    private var isResultEmpty: Bool {
        switch cell.result {
        case .text(let s): return s.isEmpty
        case .styled(let s): return s.isEmpty
        case .js(let v): return v == .undefined
        case .binary(let data, _): return data.isEmpty
        }
    }

    private var resultAlignment: VerticalAlignment {
        switch cell.result {
        case .text, .styled: return .top
        case .js, .binary: return .firstTextBaseline
        }
    }

    var body: some View {
        if cell.isSessionBoundary {
            HStack(spacing: 8) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.accentColor.opacity(0.25))

                Text("New process attached at \(cell.timestamp.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()

                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.accentColor.opacity(0.25))
            }
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 6) {
                    Text(cell.language.promptGlyph)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(cell.language.promptColor)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(cell.code)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Text(cell.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(cell.timestamp.formatted())
                }

                if !isResultEmpty {
                    HStack(alignment: resultAlignment, spacing: 6) {
                        Text("←")
                            .foregroundStyle(.secondary)

                        switch cell.result {
                        case .text(let s):
                            REPLResultText(styled: LumaCore.StyledText(s))

                        case .styled(let s):
                            REPLResultText(styled: s)

                        case .js(let v):
                            JSInspectValueView(
                                value: v,
                                sessionID: sessionID,
                                engine: engine,
                                selection: $selection
                            )

                        case .binary(let data, let meta):
                            HexView(data: data, baseAddress: meta?.baseAddress ?? 0)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("repl.cell")
            .contextMenu {
                Button {
                    addToNotebook()
                } label: {
                    Label("Add to Notebook", systemImage: "book.pages")
                }
            }
        }
    }

    private func binaryMetaString(_ meta: LumaCore.REPLCell.Result.BinaryMeta?, dataCount: Int) -> String {
        var parts: [String] = []
        if let ta = meta?.typedArray { parts.append(ta) }
        return parts.joined(separator: " • ")
    }

    private func addToNotebook() {
        let (details, styled, binary, jsValue): (String, LumaCore.StyledText?, Data?, JSInspectValue?) = {
            switch cell.result {
            case .text(let s):
                return (s, nil, nil, nil)

            case .styled(let s):
                return (s.plainText, s, nil, nil)

            case .js(let v):
                return ("", nil, nil, v)

            case .binary(let data, let meta):
                let header = binaryMetaString(meta, dataCount: data.count)
                return (header, nil, data, nil)
            }
        }()

        var entry = LumaCore.NotebookEntry(
            title: cell.code,
            details: details,
            styledDetails: styled,
            binaryData: binary,
            sessionID: sessionID,
            processName: processName
        )

        if let jsValue {
            entry.jsValue = jsValue
        }

        engine.addNotebookEntry(entry)
    }
}

private struct REPLResultText: View {
    let styled: LumaCore.StyledText

    private static let chunk = 4096
    @State private var revealed = REPLResultText.chunk

    var body: some View {
        let total = styled.plainText.count
        let shown = min(revealed, total)
        VStack(alignment: .leading, spacing: 2) {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(styled.slice(charRange: 0..<shown).attributed)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
            if shown < total {
                HStack(spacing: 12) {
                    Button("Show more") { revealed = min(revealed + Self.chunk, total) }
                    Button("Show all") { revealed = total }
                }
                .font(.caption2)
                .buttonStyle(.link)
            }
        }
    }
}

private struct REPLInputField: View {
    @Binding var text: String
    @Binding var isFocused: Bool

    #if !canImport(AppKit)
        @FocusState private var focused: Bool
    #endif

    let onCommit: (String) -> Void
    let onHistoryUp: () -> Void
    let onHistoryDown: () -> Void
    let requestCompletions: (String, Int) async -> [LumaCore.REPLCompletion]
    let language: LumaCore.REPLLanguage
    let placeholder: String

    var body: some View {
        #if canImport(AppKit)
            REPLInputFieldAppKit(
                text: $text,
                isFocused: $isFocused,
                onCommit: onCommit,
                onHistoryUp: onHistoryUp,
                onHistoryDown: onHistoryDown,
                requestCompletions: requestCompletions,
                language: language,
                placeholder: placeholder
            )
        #else
            TextField(placeholder, text: $text, axis: .horizontal)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focused)
                .onChange(of: isFocused) { _, newValue in
                    focused = newValue
                }
                .onChange(of: focused) { _, newValue in
                    isFocused = newValue
                }
                .onSubmit { onCommit(text) }
        #endif
    }
}

#if canImport(AppKit)

    private struct REPLInputFieldAppKit: NSViewRepresentable {
        @Binding var text: String
        @Binding var isFocused: Bool

        let onCommit: (String) -> Void
        let onHistoryUp: () -> Void
        let onHistoryDown: () -> Void

        let requestCompletions: (String, Int) async -> [LumaCore.REPLCompletion]
        let language: LumaCore.REPLLanguage
        let placeholder: String

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField()

            field.cell = REPLTextFieldCell()
            field.isBordered = false
            field.drawsBackground = false
            field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.focusRingType = .none
            field.lineBreakMode = .byClipping
            field.usesSingleLineMode = true
            field.isEditable = true
            field.isBezeled = false

            field.delegate = context.coordinator
            field.isAutomaticTextCompletionEnabled = true
            field.suggestionsDelegate = context.coordinator

            field.placeholderString = placeholder
            field.stringValue = text

            context.coordinator.textField = field
            return field
        }

        func updateNSView(_ nsView: NSTextField, context: Context) {
            context.coordinator.parent = self

            if nsView.placeholderString != placeholder {
                nsView.placeholderString = placeholder
            }

            if text != context.coordinator.lastSyncedText {
                context.coordinator.lastSyncedText = text
                if nsView.stringValue != text {
                    nsView.stringValue = text
                    moveInsertionToEnd(of: nsView)
                }
            }

            if isFocused,
                let window = nsView.window,
                window.firstResponder != nsView.currentEditor()
            {
                DispatchQueue.main.async { [weak nsView] in
                    guard let nsView else { return }
                    nsView.becomeFirstResponder()
                    moveInsertionToEnd(of: nsView)
                }
            }
        }

        private func moveInsertionToEnd(of field: NSTextField) {
            guard let editor = field.currentEditor() else { return }
            let end = editor.string.utf16.count
            editor.selectedRange = NSRange(location: end, length: 0)
        }

        class Coordinator: NSObject, NSTextFieldDelegate, NSTextSuggestionsDelegate {
            typealias SuggestionItemType = String

            var parent: REPLInputFieldAppKit
            weak var textField: NSTextField?

            var completionBaseText: String?
            var completionBaseCursor: Int?
            var lastSyncedText: String

            init(_ parent: REPLInputFieldAppKit) {
                self.parent = parent
                self.lastSyncedText = parent.text
            }

            func controlTextDidChange(_ obj: Notification) {
                guard let field = textField else { return }
                lastSyncedText = field.stringValue
                parent.text = field.stringValue
            }

            func controlTextDidEndEditing(_ obj: Notification) {
                parent.isFocused = false
            }

            func control(
                _ control: NSControl,
                textView: NSTextView,
                doCommandBy commandSelector: Selector
            ) -> Bool {
                if commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
                {

                    let current = textView.string
                    parent.onCommit(current)

                    lastSyncedText = ""
                    parent.text = ""
                    textField?.stringValue = ""

                    completionBaseText = nil
                    completionBaseCursor = nil

                    if let field = textField, let window = field.window {
                        window.endEditing(for: nil)

                        window.makeFirstResponder(field)

                        if let editor = field.currentEditor() {
                            editor.string = ""
                            editor.selectedRange = NSRange(location: 0, length: 0)
                        }
                    }

                    parent.isFocused = true

                    return true
                }

                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    parent.onHistoryUp()
                    return true
                }

                if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    parent.onHistoryDown()
                    return true
                }

                return false
            }

            func textField(
                _ textField: NSTextField,
                provideUpdatedSuggestions responseHandler: @escaping (ItemResponse) -> Void
            ) {
                guard let editor = textField.currentEditor() else {
                    var empty = ItemResponse(itemSections: [])
                    empty.phase = .final
                    responseHandler(empty)
                    return
                }

                let codeSnapshot = editor.string
                let cursorSnapshot = editor.selectedRange.location

                self.completionBaseText = codeSnapshot
                self.completionBaseCursor = cursorSnapshot

                if codeSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var empty = ItemResponse(itemSections: [])
                    empty.phase = .final
                    responseHandler(empty)
                    return
                }

                Task { @MainActor in
                    let suggestions = await self.parent.requestCompletions(codeSnapshot, cursorSnapshot)

                    guard editor.string == codeSnapshot, !suggestions.isEmpty else {
                        var empty = ItemResponse(itemSections: [])
                        empty.phase = .final
                        responseHandler(empty)
                        return
                    }

                    let items: [Item] = suggestions.map { suggestion in
                        var item = NSSuggestionItem(representedValue: suggestion.insertText, title: suggestion.displayText)
                        item.secondaryTitle = suggestion.detailText
                        return item
                    }

                    let section = NSSuggestionItemSection(items: items)
                    var response = ItemResponse(itemSections: [section])
                    response.phase = .final
                    responseHandler(response)
                }
            }

            func textField(_ textField: NSTextField, textCompletionFor item: Item) -> String? {
                completedText(for: item)
            }

            private func completedText(for item: Item) -> String? {
                guard let baseText = completionBaseText,
                    let baseCursor = completionBaseCursor
                else {
                    return item.representedValue
                }

                let nsText = baseText as NSString
                let length = nsText.length
                let cursor = min(max(baseCursor, 0), length)

                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._$"))

                var start = cursor
                while start > 0 {
                    let ch = nsText.character(at: start - 1)
                    if let scalar = UnicodeScalar(ch), allowed.contains(scalar) {
                        start -= 1
                    } else {
                        break
                    }
                }

                var end = cursor
                while end < length {
                    let ch = nsText.character(at: end)
                    if let scalar = UnicodeScalar(ch), allowed.contains(scalar) {
                        end += 1
                    } else {
                        break
                    }
                }

                let tokenRange = NSRange(location: start, length: end - start)
                let token = nsText.substring(with: tokenRange)
                let before = nsText.substring(to: start)
                let after = nsText.substring(from: end)

                let symbol: String = item.representedValue

                if parent.language == .r2 {
                    return before + symbol + after
                }

                let newToken: String
                if let dotIndex = token.lastIndex(of: ".") {
                    let baseExpr = String(token[..<dotIndex])
                    if baseExpr.isEmpty {
                        newToken = symbol
                    } else {
                        newToken = baseExpr + "." + symbol
                    }
                } else {
                    newToken = symbol
                }

                return before + newToken + after
            }

            func textField(_ textField: NSTextField, didSelect item: Item) {
                let completed = completedText(for: item) ?? item.representedValue

                guard let editor = textField.currentEditor() else {
                    lastSyncedText = completed
                    parent.text = completed
                    parent.isFocused = true
                    return
                }

                editor.string = completed
                let end = (completed as NSString).length
                editor.selectedRange = NSRange(location: end, length: 0)

                lastSyncedText = completed
                parent.text = completed
            }
        }
    }

    private final class REPLTextFieldCell: NSTextFieldCell {
        private lazy var replEditorInstance: NSTextView = {
            let editor = NSTextView()
            editor.isRichText = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            return editor
        }()

        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            replEditorInstance
        }

        func replEditor() -> NSTextView {
            replEditorInstance
        }
    }

#endif
