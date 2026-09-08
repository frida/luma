import Foundation
import GLibObject
import GIO
import CGLib
import GtkSource
import Gtk
import LumaCore

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@MainActor
final class TypeScriptCompletionProvider: CompletionProviderImplementation {
    var document: TypeScriptDocument?

    private let buffer: GtkSource.Buffer
    private let editorView: GtkSource.View
    private var items: [LSP.CompletionItem] = []
    private var resolved: [Int: LSP.CompletionItem] = [:]
    private var indexByProposal: [OpaquePointer: Int] = [:]
    private var proposals: [CompletionProposalImplementation] = []
    private var lastStore: GIO.ListStore?
    private var lastKey: String?

    init(buffer: GtkSource.Buffer, view: GtkSource.View) {
        self.buffer = buffer
        self.editorView = view
        super.init()
    }

    override func getTitle() -> UnsafeMutablePointer<CChar>? {
        "TypeScript".withCString { g_strdup($0) }
    }

    override func isTrigger(iter: UnsafePointer<GtkTextIter>?, ch: gunichar) -> gboolean {
        ch == gunichar(UInt32(UInt8(ascii: "."))) ? 1 : 0
    }

    override func populate(context: UnsafeMutablePointer<GtkSourceCompletionContext>?, cancellable: UnsafeMutablePointer<GCancellable>?) async throws -> UnsafeMutablePointer<GListModel>? {
        guard let context else { return nil }
        let contextRef = CompletionContextRef(context)
        let key = "\(wordBounds(contextRef))-\(buffer.text.hashValue)"
        if key == lastKey, let store = lastStore {
            return UnsafeMutableRawPointer(g_object_ref(store.list_store_ptr)).assumingMemoryBound(to: GListModel.self)
        }
        try await refresh(contextRef)
        let store = GIO.ListStore(itemType: gtk_source_completion_proposal_get_type())
        fill(GIO.ListStoreRef(store.list_store_ptr))
        lastStore = store
        lastKey = key
        return UnsafeMutableRawPointer(g_object_ref(store.list_store_ptr)).assumingMemoryBound(to: GListModel.self)
    }

    override func refilter(context: UnsafeMutablePointer<GtkSourceCompletionContext>?, model: UnsafeMutablePointer<GListModel>?) {
        guard let context, let model else { return }
        lastKey = nil
        let store = GIO.ListStoreRef(UnsafeMutableRawPointer(model).assumingMemoryBound(to: GListStore.self))
        _Concurrency.Task { @MainActor in
            try? await refresh(CompletionContextRef(context))
            store.removeAll()
            fill(store)
        }
    }

    override func display(context: UnsafeMutablePointer<GtkSourceCompletionContext>?, proposal: UnsafeMutablePointer<GtkSourceCompletionProposal>?, cell: UnsafeMutablePointer<GtkSourceCompletionCell>?) {
        guard let proposal, let cell, let index = indexByProposal[OpaquePointer(proposal)] else { return }
        let item = resolved[index] ?? items[index]
        let cellRef = CompletionCellRef(cell)
        if cellRef.column == .typedText {
            cellRef.set(text: item.label)
        } else if cellRef.column == .details {
            let label = detailLabel()
            cellRef.setWidget(child: label)
            _Concurrency.Task { @MainActor in
                label.setMarkup(str: await detailMarkup(of: item))
            }
        }
    }

    private func detailLabel() -> Gtk.Label {
        let label = Gtk.Label(str: "")
        label.wrap = true
        label.wrapMode = .wordChar
        label.lines = detailLineLimit
        label.ellipsize = .end
        label.maxWidthChars = detailWidthChars
        label.xalign = 0
        return label
    }

    private func detailMarkup(of item: LSP.CompletionItem) async -> String {
        let signature = item.detail ?? ""
        let tokens = signature.isEmpty ? [] : (await document?.classify(signature) ?? [])
        let dark = ThemeWatcher.currentAppearance() == .dark
        let units = Array(signature.utf16)
        var markup = SourceHighlighter.runs(of: signature, semanticTokens: tokens, dark: dark).map { run in
            let piece = SourceMarkup.escape(String(utf16CodeUnits: Array(units[run.range]), count: run.range.count))
            guard let color = run.color else { return piece }
            return "<span foreground=\"\(color.cssHex)\">\(piece)</span>"
        }.joined()
        if let documentation = item.documentation?.text, !documentation.isEmpty {
            if !markup.isEmpty {
                markup += "\n\n"
            }
            markup += SourceMarkup.escape(documentation)
        }
        return markup
    }

    override func activate(context: UnsafeMutablePointer<GtkSourceCompletionContext>?, proposal: UnsafeMutablePointer<GtkSourceCompletionProposal>?) {
        guard let context, let proposal, let index = indexByProposal[OpaquePointer(proposal)] else { return }
        apply(items[index], context: CompletionContextRef(context))
    }

    private func refresh(_ context: CompletionContextRef) async throws {
        guard let document else { return }
        let text = buffer.text
        let endOffset = wordBounds(context).end
        let offsets = CharacterOffsets(text: text)
        let position = LineMap(text: text).position(ofUTF16Offset: offsets.utf16Offset(ofCharacter: endOffset))
        let prefix = wordPrefix(in: text, endingAt: endOffset)
        let list = try await document.completions(at: position, triggerCharacter: prefix.isEmpty ? "." : nil)
        let ranked = rank(list.items, prefix: prefix)
        let details = await resolveDetails(of: ranked, using: document)
        guard buffer.text == text else { return }
        items = ranked
        resolved = details
    }

    private func resolveDetails(of items: [LSP.CompletionItem], using document: TypeScriptDocument) async -> [Int: LSP.CompletionItem] {
        guard items.count <= detailResolveLimit else { return [:] }
        var details: [Int: LSP.CompletionItem] = [:]
        for index in items.indices {
            details[index] = (try? await document.resolve(items[index])) ?? items[index]
        }
        return details
    }

    private func fill(_ store: GIO.ListStoreRef) {
        proposals = []
        indexByProposal = [:]
        for index in items.indices {
            let proposal = LabeledProposal(label: items[index].label)
            proposals.append(proposal)
            indexByProposal[OpaquePointer(proposal.handle)] = index
            store.append(item: GLibObject.ObjectRef(raw: UnsafeMutableRawPointer(proposal.handle)))
        }
    }

    private func apply(_ item: LSP.CompletionItem, context: CompletionContextRef) {
        let bounds = wordBounds(context)
        deleteRange(from: bounds.begin, to: bounds.end)
        let replacement = item.textEdit?.newText ?? item.insertText ?? item.label
        if item.isSnippet, let snippet = try? GtkSource.Snippet.new(parsed: replacement) {
            pushSnippet(snippet, at: bounds.begin)
        } else if isCallable(item) {
            insertCall(of: replacement, at: bounds.begin)
        } else {
            buffer.insertAtCursor(text: replacement, len: Int(replacement.utf8.count))
        }
    }

    private func isCallable(_ item: LSP.CompletionItem) -> Bool {
        [2, 3, 4].contains(item.kind ?? 0)
    }

    private func insertCall(of name: String, at start: Int) {
        let opener = name + "("
        buffer.insertAtCursor(text: opener, len: Int(opener.utf8.count))
        guard let document else { return }
        let text = buffer.text
        let position = LineMap(text: text).position(ofUTF16Offset: CharacterOffsets(text: text).utf16Offset(ofCharacter: cursorOffset()))
        _Concurrency.Task { @MainActor in
            let parameters = (try? await document.signatureHelp(at: position))?.requiredParameterNames ?? []
            guard buffer.text == text else { return }
            let template = CallTemplate(name: name, parameters: parameters)
            deleteRange(from: start, to: cursorOffset())
            if parameters.isEmpty {
                buffer.insertAtCursor(text: template.text, len: Int(template.text.utf8.count))
            } else if let snippet = try? GtkSource.Snippet.new(parsed: template.snippet) {
                pushSnippet(snippet, at: start)
            } else {
                buffer.insertAtCursor(text: template.text, len: Int(template.text.utf8.count))
            }
        }
    }

    private func pushSnippet(_ snippet: GtkSource.Snippet, at start: Int) {
        withIter { iter in
            buffer.getIterAtOffset(iter: iter, charOffset: start)
            editorView.push(snippet: snippet, location: iter)
        }
    }

    private func deleteRange(from start: Int, to end: Int) {
        withIters { first, second in
            buffer.getIterAtOffset(iter: first, charOffset: start)
            buffer.getIterAtOffset(iter: second, charOffset: end)
            buffer.delete(start: first, end: second)
        }
    }

    private func wordBounds(_ context: CompletionContextRef) -> (begin: Int, end: Int) {
        withIters { begin, end in
            _ = context.getBounds(begin: begin, end: end)
            return (Int(begin.offset), Int(end.offset))
        }
    }

    private func wordPrefix(in text: String, endingAt cursor: Int) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = min(cursor, scalars.count)
        while start > 0, isWordCharacter(Character(scalars[start - 1])) {
            start -= 1
        }
        return String(String.UnicodeScalarView(scalars[start..<min(cursor, scalars.count)]))
    }

    private func rank(_ list: [LSP.CompletionItem], prefix: String) -> [LSP.CompletionItem] {
        let needle = prefix.lowercased()
        return list
            .filter { needle.isEmpty || ($0.filterText ?? $0.label).lowercased().hasPrefix(needle) }
            .sorted { ($0.sortText ?? $0.label, $0.label) < ($1.sortText ?? $1.label, $1.label) }
    }

    private func cursorOffset() -> Int {
        withIter { iter in
            buffer.getIterAtMark(iter: iter, mark: buffer.getInsert())
            return Int(iter.offset)
        }
    }

    private func withIter<R>(_ body: (TextIter) -> R) -> R {
        let storage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { storage.deallocate() }
        return body(TextIter(storage))
    }

    private func withIters<R>(_ body: (TextIter, TextIter) -> R) -> R {
        let first = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let second = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { first.deallocate(); second.deallocate() }
        return body(TextIter(first), TextIter(second))
    }
}

private let detailResolveLimit = 100
private let detailLineLimit = 8
private let detailWidthChars = 48

private func isWordCharacter(_ character: Character) -> Bool {
    character == "_" || character == "$" || character.isLetter || character.isNumber
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class LabeledProposal: CompletionProposalImplementation {
    let label: String

    init(label: String) {
        self.label = label
        super.init()
    }

    override func getTypedText() -> UnsafeMutablePointer<CChar>? {
        label.withCString { g_strdup($0) }
    }
}
