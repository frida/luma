import Frida
import SwiftData
import SwiftUI

struct REPLView: View {
    @Bindable var session: ProcessSession
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var inputCode: String = ""
    @State private var isInputFocused: Bool = false

    @State private var historyCursor: Int = 0
    @State private var historyCursorInitialized = false

    @Environment(\.modelContext) private var modelContext

    private var node: ProcessNode? {
        workspace.processNodes.first { $0.sessionRecord == session }
    }

    var body: some View {
        VStack(spacing: 0) {
            if node == nil {
                SessionDetachedBanner(session: session, workspace: workspace)
            }

            GeometryReader { outerGeo in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(session.orderedReplCells) { cell in
                                REPLCellView(
                                    cell: cell,
                                    processName: session.processName,
                                    sessionID: session.id,
                                    workspace: workspace,
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
                        .padding(.horizontal)

                        Color.clear
                            .frame(height: 2)
                            .id("repl-bottom-anchor")
                    }
                    .onAppear {
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: session.replCells.count) {
                        scrollToBottom(proxy: proxy)
                    }
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Text("›")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let node {
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
                            await node.completeInREPL(code: code, cursor: cursor)
                        }
                    )
                    .frame(minHeight: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ZStack(alignment: .leading) {
                        REPLInputField(
                            text: .constant(""),
                            isFocused: .constant(false),
                            onCommit: { _ in },
                            onHistoryUp: {},
                            onHistoryDown: {},
                            requestCompletions: { _, _ in [] as [String] }
                        )
                        .disabled(true)
                        .opacity(0.35)
                        .frame(minHeight: 22)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Session detached — click \(session.kind.reestablishLabel) to continue.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                    .help("Detached — re-establish this session from the sidebar before running commands.")
                }

                Button {
                    runCurrentInput()
                } label: {
                    Image(systemName: "return")
                }
                .buttonStyle(.borderless)
                .help("Run")
                .disabled(node == nil)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onAppear {
            DispatchQueue.main.async {
                isInputFocused = node != nil

                if !historyCursorInitialized {
                    historyCursor = session.orderedReplCells.count
                    historyCursorInitialized = true
                }
            }
        }
        .contextMenu {
            Button {
                clearHistory()
            } label: {
                Label("Clear History", systemImage: "trash")
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo("repl-bottom-anchor", anchor: .bottom)
        }
    }

    private func clearHistory() {
        for cell in session.replCells {
            modelContext.delete(cell)
        }
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

        Task { @MainActor in
            await node!.evalInREPL(code)
            historyCursor = session.orderedReplCells.count
        }

        isInputFocused = true
    }

    private func historyPrevious() {
        let history = session.orderedReplCells
        guard !history.isEmpty else {
            return
        }

        if historyCursor != 0 {
            historyCursor -= 1
        }

        inputCode = history[historyCursor].code
    }

    private func historyNext() {
        let history = session.orderedReplCells
        guard !history.isEmpty else {
            return
        }

        if historyCursor < history.count - 1 {
            historyCursor += 1
            inputCode = history[historyCursor].code
        } else {
            historyCursor = history.count
            inputCode = ""
        }
    }
}

private struct REPLCellView: View {
    let cell: REPLCell
    let processName: String
    let sessionID: UUID
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if cell.isSessionBoundary {
            HStack(spacing: 8) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.accentColor.opacity(0.25))

                Text("New process attached at \(cell.timestamp.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.accentColor.opacity(0.25))
            }
            .padding(.vertical, 4)
        } else {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("›")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(cell.code)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("←")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)

                        switch cell.result {
                        case .text(let s):
                            Text(s)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)

                        case .js(let v):
                            JSInspectValueView(
                                value: v,
                                sessionID: sessionID,
                                workspace: workspace,
                                selection: $selection
                            )

                        case .binary(let data, _):
                            HexView(data: data)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer()

                Text(cell.timestamp.formatted())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            .contextMenu {
                Button {
                    addToNotebook()
                } label: {
                    Label("Add to Notebook", systemImage: "book.pages")
                }
            }
        }
    }

    private func binaryMetaString(_ meta: REPLCell.Result.BinaryMeta?, dataCount: Int) -> String {
        var parts: [String] = []
        if let ta = meta?.typedArray { parts.append(ta) }
        return parts.joined(separator: " • ")
    }

    private func addToNotebook() {
        let (details, binary, jsValue): (String, Data?, JSInspectValue?) = {
            switch cell.result {
            case .text(let s):
                return (s, nil, nil)

            case .js(let v):
                return ("", nil, v)

            case .binary(let data, let meta):
                let header = binaryMetaString(meta, dataCount: data.count)
                return (header, data, nil)
            }
        }()

        let entry = NotebookEntry(
            title: cell.code,
            details: details,
            binaryData: binary,
            processName: processName
        )

        if let jsValue {
            entry.jsValue = jsValue
        }

        workspace.addNotebookEntry(entry)
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
    let requestCompletions: (String, Int) async -> [String]

    var body: some View {
        #if canImport(AppKit)
            REPLInputFieldAppKit(
                text: $text,
                isFocused: $isFocused,
                onCommit: onCommit,
                onHistoryUp: onHistoryUp,
                onHistoryDown: onHistoryDown,
                requestCompletions: requestCompletions
            )
        #else
            TextField("", text: $text, axis: .horizontal)
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

        let requestCompletions: (String, Int) async -> [String]

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

            context.coordinator.textField = field
            return field
        }

        func updateNSView(_ nsView: NSTextField, context: Context) {
            if nsView.stringValue != text {
                nsView.stringValue = text
                moveInsertionToEnd(of: nsView)
            }

            if isFocused,
                let window = nsView.window,
                window.firstResponder != nsView.currentEditor()
            {
                nsView.becomeFirstResponder()
                moveInsertionToEnd(of: nsView)
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

            init(_ parent: REPLInputFieldAppKit) {
                self.parent = parent
            }

            func controlTextDidChange(_ obj: Notification) {
                guard let field = textField else { return }
                parent.text = field.stringValue
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
                        NSSuggestionItem(representedValue: suggestion, title: suggestion)
                    }

                    let section = NSSuggestionItemSection(items: items)
                    var response = ItemResponse(itemSections: [section])
                    response.phase = .final
                    responseHandler(response)
                }
            }

            func textField(_ textField: NSTextField, textCompletionFor item: Item) -> String? {
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
                guard let editor = textField.currentEditor() else {
                    parent.text = textField.stringValue
                    parent.isFocused = true
                    return
                }

                let selection = editor.selectedRange
                let end = selection.location + selection.length

                editor.selectedRange = NSRange(location: end, length: 0)

                parent.text = editor.string
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
