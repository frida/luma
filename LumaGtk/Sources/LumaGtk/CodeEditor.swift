import Adw
import CGtk
import CLuma
import Foundation
import GLibObject
import Gdk
import Gtk
import GtkSource
import LumaCore

@MainActor
public final class CodeEditor {
    public let widget: Box
    public var onTextChanged: ((String) -> Void)?
    public var onCommit: (() -> Void)?

    private weak var engine: Engine?
    private let editor: GtkSource.View
    private let buffer: GtkSource.Buffer
    private let scroll: ScrolledWindow
    private let find: PharoFindBar
    private let highlighter: LexicalHighlighter
    private let semanticHighlighter: CodeSemanticHighlighter
    private let diagnosticMarks: CodeDiagnosticMarks
    private let hover: CodeHoverTooltip
    private let completion: TypeScriptCompletionProvider
    private let indenter: TypeScriptIndenter
    private let signatureHelp: CodeSignatureHelp
    private var profile: EditorProfile
    private var text: String
    private var suppressChange = false
    private var session: TypeScriptEditorSession?
    private var sessionGeneration = 0
    private var themeSubscription: gulong = 0

    public init(engine: Engine?, profile: EditorProfile = .init(), initialText: String = "") {
        self.engine = engine
        self.profile = profile
        self.text = initialText

        buffer = GtkSource.Buffer(table: Gtk.TextTagTable?.none)
        buffer.highlightSyntax = false
        buffer.highlightMatchingBrackets = true
        editor = GtkSource.View(buffer: buffer)
        editor.monospace = true
        editor.enableSnippets = true
        editor.showLineNumbers = true
        editor.highlightCurrentLine = true
        editor.autoIndent = true
        editor.smartBackspace = true
        editor.indentOnTab = true
        editor.insertSpacesInsteadOfTabs = true
        editor.tabWidth = 4
        editor.indentWidth = 4
        editor.leftMargin = 6
        editor.rightMargin = 10
        editor.topMargin = 8
        editor.bottomMargin = 18
        editor.hexpand = true
        editor.vexpand = true
        editor.editable = !profile.readOnly
        buffer.set(text: initialText, len: Int(initialText.utf8.count))

        scroll = ScrolledWindow()
        scroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .automatic)
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: editor)

        find = PharoFindBar(editor: editor, buffer: buffer)

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true
        widget.append(child: find.widget)
        widget.append(child: scroll)

        highlighter = LexicalHighlighter(buffer: buffer)
        semanticHighlighter = CodeSemanticHighlighter(buffer: buffer)
        diagnosticMarks = CodeDiagnosticMarks(buffer: buffer)
        hover = CodeHoverTooltip(editor: editor, buffer: buffer, diagnostics: diagnosticMarks)
        completion = TypeScriptCompletionProvider(buffer: buffer, view: editor)
        editor.completion?.add(provider: CompletionProviderRef(completion.handle))
        indenter = TypeScriptIndenter(buffer: buffer)
        editor.set(indenter: IndenterRef(indenter.handle))
        buffer.setHighlightMatchingBrackets(highlight: true)
        signatureHelp = CodeSignatureHelp(editor: editor, buffer: buffer)

        highlighter.apply(to: initialText)
        installKeys()
        buffer.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.noteBufferChanged() }
        }
        applyStyleScheme()
        themeSubscription = ThemeWatcher.subscribe(owner: self) { $0.retheme() }
        restartSession()
    }

    private func retheme() {
        applyStyleScheme()
        highlighter.apply(to: text)
        semanticHighlighter.retheme()
    }

    private func applyStyleScheme() {
        let dark = ThemeWatcher.currentAppearance() == .dark
        guard let scheme = GtkSource.StyleSchemeManager.getDefault()?.getScheme(schemeId: dark ? "Adwaita-dark" : "Adwaita") else { return }
        buffer.styleScheme = scheme
    }

    deinit {
        ThemeWatcher.unsubscribe(handlerID: themeSubscription)
        MainActor.assumeIsolated {
            session?.close()
        }
    }

    public func attach(engine: Engine) {
        self.engine = engine
        restartSession()
    }

    public func installInto(_ host: Box) {
        reparent(into: host)
    }

    public func reparent(into container: Box) {
        if let parent = widget.parent {
            BoxRef(raw: parent.ptr).remove(child: widget)
        }
        container.append(child: widget)
    }

    public func focus() {
        _ = editor.grabFocus()
    }

    public func setText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        suppressChange = true
        buffer.set(text: newText, len: Int(newText.utf8.count))
        suppressChange = false
        highlighter.apply(to: newText)
        session?.document.replaceText(newText)
    }

    public func setProfile(_ newProfile: EditorProfile) {
        let needsNewSession = !TypeScriptEditorSession.isSameProject(newProfile, profile)
        profile = newProfile
        editor.editable = !newProfile.readOnly
        if needsNewSession {
            restartSession()
        }
    }

    private func restartSession() {
        sessionGeneration += 1
        let generation = sessionGeneration
        session?.close()
        session = nil
        completion.document = nil
        signatureHelp.document = nil
        hover.document = nil
        diagnosticMarks.apply([], to: text)
        semanticHighlighter.setTokens([], to: text)
        guard let engine else { return }
        let profile = profile
        let text = text
        Task { @MainActor in
            guard let session = try? await TypeScriptEditorSession.open(engine: engine, profile: profile, text: text),
                generation == self.sessionGeneration
            else { return }
            self.adopt(session)
        }
    }

    private func adopt(_ session: TypeScriptEditorSession) {
        self.session = session
        session.document.replaceText(text)
        session.document.onDiagnostics = { [weak self] diagnostics in
            guard let self else { return }
            self.diagnosticMarks.apply(diagnostics, to: self.text)
            self.semanticHighlighter.setUnused(self.diagnosticMarks.unusedRanges(in: self.text), to: self.text)
        }
        session.document.onSemanticTokens = { [weak self] tokens in
            guard let self else { return }
            self.semanticHighlighter.setTokens(tokens, to: self.text)
        }
        completion.document = session.document
        signatureHelp.document = session.document
        hover.document = session.document
    }

    private func noteBufferChanged() {
        guard !suppressChange else { return }
        text = buffer.text
        highlighter.apply(to: text)
        session?.document.replaceText(text)
        onTextChanged?(text)
    }

    private func installKeys() {
        let keys = EventControllerKey()
        keys.propagationPhase = .capture
        keys.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                guard let self else { return false }
                if state.contains(.controlMask), isEnter(keyval), let onCommit = self.onCommit {
                    onCommit()
                    return true
                }
                return self.signatureHelp.handleKey(keyval)
            }
        }
        editor.add(controller: keys)
    }
}

private func isEnter(_ keyval: UInt) -> Bool {
    switch Int32(keyval) {
    case Gdk.keyReturn, Gdk.keyKPEnter, Gdk.keyISOEnter:
        return true
    default:
        return false
    }
}

@MainActor
final class LexicalHighlighter {
    private let buffer: GtkSource.Buffer
    private var tagNames: [Bool: [TypeScriptToken.Kind: String]] = [:]
    private var everyName: [String] = []

    init(buffer: GtkSource.Buffer) {
        self.buffer = buffer
        for dark in [false, true] {
            var names: [TypeScriptToken.Kind: String] = [:]
            for kind in [TypeScriptToken.Kind.keyword, .string, .template, .number, .regex, .comment] {
                guard let style = SourceSyntaxPalette.style(for: kind, dark: dark) else { continue }
                let name = "syntax-\(kind)-\(dark ? "dark" : "light")"
                _ = luma_text_buffer_create_style_tag(buffer.ptr, name, style.color.cssHex, style.bold, style.italic)
                names[kind] = name
                everyName.append(name)
            }
            tagNames[dark] = names
        }
    }

    func apply(to text: String) {
        let names = tagNames[ThemeWatcher.currentAppearance() == .dark] ?? [:]
        let offsets = CharacterOffsets(text: text)
        withIters { start, end in
            buffer.getBounds(start: start, end: end)
            for name in everyName {
                buffer.removeTagBy(name: name, start: start, end: end)
            }
            for token in TypeScriptLexer.tokenize(text) {
                guard let name = names[token.kind] else { continue }
                buffer.getIterAtOffset(iter: start, charOffset: offsets.characterOffset(ofUTF16: token.utf16Range.lowerBound))
                buffer.getIterAtOffset(iter: end, charOffset: offsets.characterOffset(ofUTF16: token.utf16Range.upperBound))
                buffer.applyTagBy(name: name, start: start, end: end)
            }
        }
    }

    private func withIters<R>(_ body: (TextIter, TextIter) -> R) -> R {
        let first = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let second = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer {
            first.deallocate()
            second.deallocate()
        }
        return body(TextIter(first), TextIter(second))
    }
}

@MainActor
final class CodeSemanticHighlighter {
    private let buffer: GtkSource.Buffer
    private var tagNamesByColor: [String: String] = [:]
    private var tokens: [SemanticToken] = []
    private var unused: [Swift.Range<Int>] = []
    private var text = ""

    init(buffer: GtkSource.Buffer) {
        self.buffer = buffer
    }

    func setTokens(_ newTokens: [SemanticToken], to newText: String) {
        tokens = newTokens
        text = newText
        reapply()
    }

    func setUnused(_ ranges: [Swift.Range<Int>], to newText: String) {
        unused = ranges
        text = newText
        reapply()
    }

    func retheme() {
        reapply()
    }

    private func reapply() {
        let dark = ThemeWatcher.currentAppearance() == .dark
        let lineMap = LineMap(text: text)
        let offsets = CharacterOffsets(text: text)
        withIters { start, end in
            buffer.getBounds(start: start, end: end)
            for name in tagNamesByColor.values {
                buffer.removeTagBy(name: name, start: start, end: end)
            }
            for token in tokens {
                let lower = lineMap.utf16Offset(of: LSP.Position(line: token.line, character: token.character))
                let upper = lower + token.length
                let faded = unused.contains { $0.overlaps(lower..<upper) }
                guard let style = colorStyle(for: token, faded: faded, dark: dark) else { continue }
                buffer.getIterAtOffset(iter: start, charOffset: offsets.characterOffset(ofUTF16: lower))
                buffer.getIterAtOffset(iter: end, charOffset: offsets.characterOffset(ofUTF16: upper))
                buffer.applyTagBy(name: tagName(for: style), start: start, end: end)
            }
        }
    }

    private func colorStyle(for token: SemanticToken, faded: Bool, dark: Bool) -> SourceSyntaxStyle? {
        if faded {
            return SourceSyntaxPalette.fadedSemanticStyle(for: token.type, modifiers: token.modifiers, dark: dark)
        }
        return SourceSyntaxPalette.semanticStyle(for: token.type, modifiers: token.modifiers, dark: dark)
    }

    private func tagName(for style: SourceSyntaxStyle) -> String {
        let color = style.color.cssHex
        if let name = tagNamesByColor[color] {
            return name
        }
        let name = "semantic-\(tagNamesByColor.count)"
        _ = luma_text_buffer_create_style_tag(buffer.ptr, name, color, style.bold, style.italic)
        tagNamesByColor[color] = name
        return name
    }

    private func withIters<R>(_ body: (TextIter, TextIter) -> R) -> R {
        let first = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let second = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer {
            first.deallocate()
            second.deallocate()
        }
        return body(TextIter(first), TextIter(second))
    }
}

@MainActor
final class CodeDiagnosticMarks {
    private let buffer: GtkSource.Buffer
    private var diagnostics: [(utf16Range: Swift.Range<Int>, diagnostic: LSP.Diagnostic)] = []

    init(buffer: GtkSource.Buffer) {
        self.buffer = buffer
        _ = luma_text_buffer_create_underline_tag(buffer.ptr, "diagnostic-error", "#e01b24", true)
        _ = luma_text_buffer_create_underline_tag(buffer.ptr, "diagnostic-warning", "#e5a50a", false)
    }

    func apply(_ newDiagnostics: [LSP.Diagnostic], to text: String) {
        let lineMap = LineMap(text: text)
        let offsets = CharacterOffsets(text: text)
        diagnostics = newDiagnostics.map { (lineMap.utf16Range(of: $0.range), $0) }
        withIters { start, end in
            buffer.getBounds(start: start, end: end)
            buffer.removeTagBy(name: "diagnostic-error", start: start, end: end)
            buffer.removeTagBy(name: "diagnostic-warning", start: start, end: end)
            for (range, diagnostic) in diagnostics where !diagnostic.isUnnecessary {
                let markedRange = range.isEmpty ? range.lowerBound..<min(range.lowerBound + 1, lineMap.utf16Count) : range
                buffer.getIterAtOffset(iter: start, charOffset: offsets.characterOffset(ofUTF16: markedRange.lowerBound))
                buffer.getIterAtOffset(iter: end, charOffset: offsets.characterOffset(ofUTF16: markedRange.upperBound))
                buffer.applyTagBy(name: diagnostic.isError ? "diagnostic-error" : "diagnostic-warning", start: start, end: end)
            }
        }
    }

    func unusedRanges(in text: String) -> [Swift.Range<Int>] {
        let lineMap = LineMap(text: text)
        return diagnostics.filter { $0.diagnostic.isUnnecessary }.map { lineMap.utf16Range(of: $0.diagnostic.range) }
    }

    func messages(atUTF16Offset offset: Int) -> [String] {
        diagnostics
            .filter { $0.utf16Range.contains(offset) || $0.utf16Range.lowerBound == offset }
            .map { $0.diagnostic.message }
    }

    private func withIters<R>(_ body: (TextIter, TextIter) -> R) -> R {
        let first = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let second = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer {
            first.deallocate()
            second.deallocate()
        }
        return body(TextIter(first), TextIter(second))
    }
}

@MainActor
final class CodeHoverTooltip {
    var document: TypeScriptDocument?

    private let editor: GtkSource.View
    private let buffer: GtkSource.Buffer
    private let diagnostics: CodeDiagnosticMarks
    private var answered: (offset: Int, markup: String?)?
    private var pending: Task<Void, Never>?

    init(editor: GtkSource.View, buffer: GtkSource.Buffer, diagnostics: CodeDiagnosticMarks) {
        self.editor = editor
        self.buffer = buffer
        self.diagnostics = diagnostics
        editor.hasTooltip = true
        editor.onQueryTooltip { [weak self] _, x, y, _, tooltip in
            MainActor.assumeIsolated {
                self?.answer(tooltip, x: x, y: y) ?? false
            }
        }
    }

    private func answer(_ tooltip: TooltipRef, x: Int, y: Int) -> Bool {
        guard let offset = utf16Offset(atWindowX: x, y: y) else { return false }
        var segments = diagnostics.messages(atUTF16Offset: offset).map(SourceMarkup.escape)
        if let answered, answered.offset == offset {
            if let signature = answered.markup, !signature.isEmpty {
                segments.append(signature)
            }
        } else {
            requestHover(atUTF16Offset: offset)
        }
        let markup = segments.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markup.isEmpty else { return false }
        tooltip.set(markup: markup)
        return true
    }

    private func requestHover(atUTF16Offset offset: Int) {
        guard let document else { return }
        pending?.cancel()
        let position = LineMap(text: document.text).position(ofUTF16Offset: offset)
        pending = Task { @MainActor in
            let hover = try? await document.hover(at: position)
            guard !Task.isCancelled else { return }
            let text = hover?.contents.text ?? ""
            let markup = text.isEmpty ? nil : await SourceMarkup.highlight(text, dark: true) { await document.classify($0) }
            guard !Task.isCancelled else { return }
            answered = (offset, markup)
            editor.triggerTooltipQuery()
        }
    }

    private func utf16Offset(atWindowX x: Int, y: Int) -> Int? {
        var bufferX: gint = 0
        var bufferY: gint = 0
        editor.windowToBufferCoords(win: .widget, windowX: x, windowY: y, bufferX: &bufferX, bufferY: &bufferY)
        let storage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { storage.deallocate() }
        let iter = TextIter(storage)
        guard editor.getIterAtLocation(iter: iter, x: Int(bufferX), y: Int(bufferY)) else { return nil }
        return CharacterOffsets(text: buffer.text).utf16Offset(ofCharacter: Int(iter.offset))
    }
}

enum SourceMarkup {
    @MainActor
    static func highlight(_ text: String, dark: Bool, classify: (String) async -> [SemanticToken]) async -> String {
        var result = ""
        for segment in HoverMarkdown.segments(text) {
            if !result.isEmpty {
                result += "\n\n"
            }
            if segment.isCode {
                result += await code(segment.text, dark: dark, classify: classify)
            } else {
                result += escape(segment.text)
            }
        }
        return result
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    @MainActor
    private static func code(_ body: String, dark: Bool, classify: (String) async -> [SemanticToken]) async -> String {
        let units = Array(body.utf16)
        return SourceHighlighter.runs(of: body, semanticTokens: await classify(body), dark: dark).map { run in
            let piece = escape(String(utf16CodeUnits: Array(units[run.range]), count: run.range.count))
            guard let color = run.color else { return piece }
            return "<span foreground=\"\(color.cssHex)\">\(piece)</span>"
        }.joined()
    }
}

struct CharacterOffsets {
    private let text: String

    init(text: String) {
        self.text = text
    }

    func characterOffset(ofUTF16 offset: Int) -> Int {
        let index = text.utf16.index(text.utf16.startIndex, offsetBy: offset, limitedBy: text.utf16.endIndex) ?? text.utf16.endIndex
        return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: index)
    }

    func utf16Offset(ofCharacter offset: Int) -> Int {
        let scalars = text.unicodeScalars
        let index = scalars.index(scalars.startIndex, offsetBy: offset, limitedBy: scalars.endIndex) ?? scalars.endIndex
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }
}

extension RGBColor {
    var cssHex: String {
        String(format: "#%02x%02x%02x", r, g, b)
    }
}
