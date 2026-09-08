import LumaCore
import SwiftUI

#if canImport(AppKit)
    import AppKit

    typealias CodeTextViewBase = NSTextView
#else
    import UIKit

    typealias CodeTextViewBase = UITextView
#endif

final class CodeTextView: CodeTextViewBase {
    var onEdit: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var sourceFont = PlatformFont.monospacedSystemFont(ofSize: PlatformFont.systemFontSize, weight: .regular) {
        didSet { restyle() }
    }

    var session: TypeScriptEditorSession? {
        didSet { bindSession() }
    }

    private var diagnostics: [LSP.Diagnostic] = []
    private var semanticTokens: [SemanticToken] = []
    private var fetched: [LSP.CompletionItem] = []
    private var isReplacingSource = false

    #if canImport(AppKit)
        private let completionPanel = CodeCompletionPanel()
        private let hover = CodeInfoPopover()
        private let signature = CodeInfoPopover()
        private var hoverRequest: DispatchWorkItem?
        private var signatureRequest: Task<Void, Never>?
        private var argumentPlaceholders: [NSRange] = []
    #else
        private let candidates = CompletionCandidates()
        private let completionBarHeight: CGFloat = 38

        init() {
            let container = NSTextContainer(
                size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            let layout = NSLayoutManager()
            layout.addTextContainer(container)
            let storage = NSTextStorage()
            storage.addLayoutManager(layout)
            super.init(frame: .zero, textContainer: container)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("CodeTextView is not loaded from a nib")
        }
    #endif

    var source: String {
        storage.string
    }

    func setSource(_ newSource: String) {
        isReplacingSource = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newSource)
        isReplacingSource = false
        restyle()
        session?.document.replaceText(newSource)
    }

    private func bindSession() {
        guard let session else {
            diagnostics = []
            semanticTokens = []
            restyle()
            return
        }
        session.document.replaceText(source)
        session.document.onDiagnostics = { [weak self] diagnostics in
            self?.diagnostics = diagnostics
            self?.restyle()
        }
        session.document.onSemanticTokens = { [weak self] tokens in
            self?.semanticTokens = tokens
            self?.restyle()
        }
    }

    func noteEdited() {
        guard !isReplacingSource else { return }
        let text = source
        restyle()
        session?.document.replaceText(text)
        onEdit?(text)
    }

    private func restyle() {
        let text = source
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: sourceFont, .foregroundColor: PlatformColor.platformLabel], range: whole)
        for token in TypeScriptLexer.tokenize(text) {
            guard let style = SourceSyntaxPalette.style(for: token.kind, dark: false),
                let darkStyle = SourceSyntaxPalette.style(for: token.kind, dark: true)
            else { continue }
            let range = NSRange(location: token.utf16Range.lowerBound, length: token.utf16Range.count)
            storage.addAttribute(.foregroundColor, value: PlatformColor.syntaxRun(light: style.color, dark: darkStyle.color), range: range)
            if style.bold {
                storage.addAttribute(.font, value: boldSourceFont, range: range)
            }
        }
        let lineMap = LineMap(text: text)
        let unused = diagnostics.filter(\.isUnnecessary).map { lineMap.utf16Range(of: $0.range) }
        for token in semanticTokens {
            let lower = lineMap.utf16Offset(of: LSP.Position(line: token.line, character: token.character))
            let upper = min(lower + token.length, storage.length)
            guard lower < upper else { continue }
            let faded = unused.contains { $0.overlaps(lower..<upper) }
            guard let color = semanticColor(for: token, faded: faded) else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: lower, length: upper - lower))
        }
        for diagnostic in diagnostics where !diagnostic.isUnnecessary {
            let range = lineMap.utf16Range(of: diagnostic.range)
            let marked = range.isEmpty ? range.lowerBound..<min(range.lowerBound + 1, lineMap.utf16Count) : range
            guard !marked.isEmpty else { continue }
            storage.addAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: diagnostic.isError ? PlatformColor.systemRed : PlatformColor.systemOrange,
                ],
                range: NSRange(location: marked.lowerBound, length: marked.count))
        }
        storage.endEditing()
    }

    private func semanticColor(for token: SemanticToken, faded: Bool) -> PlatformColor? {
        if faded {
            return PlatformColor.syntaxRun(
                light: SourceSyntaxPalette.fadedSemanticStyle(for: token.type, modifiers: token.modifiers, dark: false).color,
                dark: SourceSyntaxPalette.fadedSemanticStyle(for: token.type, modifiers: token.modifiers, dark: true).color)
        }
        guard let light = SourceSyntaxPalette.semanticStyle(for: token.type, modifiers: token.modifiers, dark: false),
            let dark = SourceSyntaxPalette.semanticStyle(for: token.type, modifiers: token.modifiers, dark: true)
        else { return nil }
        return PlatformColor.syntaxRun(light: light.color, dark: dark.color)
    }

    private var boldSourceFont: PlatformFont {
        #if canImport(AppKit)
            return NSFontManager.shared.convert(sourceFont, toHaveTrait: .boldFontMask)
        #else
            return PlatformFont.monospacedSystemFont(ofSize: sourceFont.pointSize, weight: .bold)
        #endif
    }

    private var storage: NSTextStorage {
        #if canImport(AppKit)
            return textStorage!
        #else
            return textStorage
        #endif
    }

    private var caret: Int {
        #if canImport(AppKit)
            return selectedRange().location
        #else
            return selectedRange.location
        #endif
    }

    private var caretPosition: LSP.Position {
        LineMap(text: source).position(ofUTF16Offset: caret)
    }

    var completionWordRange: NSRange {
        let units = Array(source.utf16)
        let cursor = min(caret, units.count)
        var start = cursor
        while start > 0, isWordUnit(units[start - 1]) { start -= 1 }
        return NSRange(location: start, length: cursor - start)
    }

    private func isWordUnit(_ unit: UTF16.CodeUnit) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit == 36
    }

    func askForCompletions(trigger: String?) {
        guard let document = session?.document else { return }
        let text = source
        let position = caretPosition
        Task { @MainActor in
            guard let list = try? await document.completions(at: position, triggerCharacter: trigger), self.source == text else { return }
            fetched = list.items.sorted { ($0.sortText ?? $0.label, $0.label) < ($1.sortText ?? $1.label, $1.label) }
            offerCompletions()
        }
    }

    private func matchingCandidates() -> [LSP.CompletionItem] {
        let prefix = (source as NSString).substring(with: completionWordRange).lowercased()
        return fetched.filter { prefix.isEmpty || ($0.filterText ?? $0.label).lowercased().hasPrefix(prefix) }
    }

    private func insertion(for item: LSP.CompletionItem) -> String {
        let text = item.textEdit?.newText ?? item.insertText ?? item.label
        return item.isSnippet ? CodeSnippetText.plain(text) : text
    }

    private func isCallable(_ item: LSP.CompletionItem) -> Bool {
        [2, 3, 4].contains(item.kind ?? 0)
    }

    private func replace(_ range: NSRange, with replacement: String) {
        #if canImport(AppKit)
            super.insertText(replacement, replacementRange: range)
        #else
            storage.replaceCharacters(in: range, with: replacement)
            noteEdited()
        #endif
    }

    private func moveCaret(to offset: Int) {
        let range = NSRange(location: offset, length: 0)
        #if canImport(AppKit)
            setSelectedRange(range, affinity: .downstream, stillSelecting: false)
        #else
            selectedRange = range
        #endif
    }

    #if canImport(AppKit)
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocused?() }
            return became
        }

        override func resignFirstResponder() -> Bool {
            completionPanel.dismiss()
            signature.dismiss()
            return super.resignFirstResponder()
        }

        override func didChangeText() {
            super.didChangeText()
            noteEdited()
        }

        override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
            if allowed {
                shiftPlaceholders(for: affectedCharRange, replacementLength: (replacementString ?? "").utf16.count)
            }
            return allowed
        }

        override func insertText(_ string: Any, replacementRange: NSRange) {
            let typed = (string as? String).flatMap { $0.utf16.count == 1 ? $0.utf16.first : nil }
            if let typed, isCloser(typed), selectedRange().length == 0,
                let dedent = SourceIndentation.closerDedent(in: source, atUTF16: caret)
            {
                super.insertText("", replacementRange: NSRange(location: dedent.lowerBound, length: dedent.count))
            }
            super.insertText(string, replacementRange: replacementRange)
            guard let typed else { return }
            if isWordUnit(typed) {
                askForCompletions(trigger: nil)
            } else if typed == 0x2E {
                askForCompletions(trigger: ".")
            } else {
                completionPanel.dismiss()
            }
            if typed == 0x28 || typed == 0x2C || signature.isShown {
                askForSignatureHelp()
            }
            if typed == 0x29 {
                signature.dismiss()
            }
        }

        private func isCloser(_ unit: UTF16.CodeUnit) -> Bool {
            unit == 0x29 || unit == 0x5D || unit == 0x7D
        }

        override func insertNewline(_ sender: Any?) {
            completionPanel.dismiss()
            let selection = selectedRange()
            let newline = SourceIndentation.newline(in: source, atUTF16: selection.location)
            super.insertText(newline.text, replacementRange: selection)
            moveCaret(to: selection.location + newline.caretOffset)
        }

        override func insertTab(_ sender: Any?) {
            if selectPlaceholder(forward: true) { return }
            super.insertText(SourceIndentation.unit, replacementRange: selectedRange())
        }

        override func insertBacktab(_ sender: Any?) {
            _ = selectPlaceholder(forward: false)
        }

        override func deleteBackward(_ sender: Any?) {
            if selectedRange().length == 0, let dedent = SourceIndentation.backspaceDedent(in: source, atUTF16: caret) {
                super.insertText("", replacementRange: NSRange(location: dedent.lowerBound, length: dedent.count))
                return
            }
            super.deleteBackward(sender)
        }

        override func doCommand(by selector: Selector) {
            if completionPanel.isShown {
                switch selector {
                case #selector(moveUp(_:)):
                    completionPanel.moveSelection(by: -1)
                    return
                case #selector(moveDown(_:)):
                    completionPanel.moveSelection(by: 1)
                    return
                case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                    if let item = completionPanel.selectedItem {
                        acceptCompletion(item)
                    }
                    return
                case #selector(cancelOperation(_:)):
                    completionPanel.dismiss()
                    return
                default:
                    break
                }
            }
            if selector == #selector(cancelOperation(_:)), signature.isShown {
                signature.dismiss()
                return
            }
            super.doCommand(by: selector)
        }

        override func complete(_ sender: Any?) {
            askForCompletions(trigger: nil)
        }

        private func offerCompletions() {
            let matching = matchingCandidates()
            guard !matching.isEmpty else {
                completionPanel.dismiss()
                return
            }
            completionPanel.onAccept = { [weak self] item in self?.acceptCompletion(item) }
            completionPanel.describe = { [weak self] item in
                (try? await self?.session?.document.resolve(item)) ?? item
            }
            completionPanel.classify = { [weak self] code in
                await self?.session?.document.classify(code) ?? []
            }
            let anchor = firstRect(forCharacterRange: NSRange(location: completionWordRange.location, length: 0), actualRange: nil)
            completionPanel.show(matching, belowScreenRect: anchor, of: self)
        }

        private func acceptCompletion(_ item: LSP.CompletionItem) {
            completionPanel.dismiss()
            let range = completionWordRange
            let name = item.textEdit?.newText ?? item.insertText ?? item.label
            guard !item.isSnippet, isCallable(item), let document = session?.document else {
                replace(range, with: insertion(for: item))
                return
            }
            replace(range, with: name + "(")
            let text = source
            let position = caretPosition
            Task { @MainActor in
                let parameters = (try? await document.signatureHelp(at: position))?.requiredParameterNames ?? []
                guard source == text else { return }
                layDownCall(CallTemplate(name: name, parameters: parameters), from: range.location)
            }
        }

        private func layDownCall(_ template: CallTemplate, from start: Int) {
            replace(NSRange(location: start, length: caret - start), with: template.text)
            argumentPlaceholders = template.placeholders.map { NSRange(location: start + $0.lowerBound, length: $0.count) }
            if let first = argumentPlaceholders.first {
                setSelectedRange(first)
            } else {
                moveCaret(to: start + template.text.utf16.count)
            }
        }

        private func selectPlaceholder(forward: Bool) -> Bool {
            guard !argumentPlaceholders.isEmpty else { return false }
            let current = selectedRange()
            let ordered = argumentPlaceholders.sorted { $0.location < $1.location }
            let next = forward
                ? ordered.first { $0.location > current.location } ?? ordered.first
                : ordered.last { $0.location < current.location } ?? ordered.last
            guard let next else { return false }
            setSelectedRange(next)
            return true
        }

        private func shiftPlaceholders(for edited: NSRange, replacementLength: Int) {
            guard !argumentPlaceholders.isEmpty else { return }
            let delta = replacementLength - edited.length
            argumentPlaceholders = argumentPlaceholders.compactMap { placeholder in
                if placeholder.location >= NSMaxRange(edited) {
                    return NSRange(location: placeholder.location + delta, length: placeholder.length)
                }
                if NSMaxRange(placeholder) <= edited.location {
                    return placeholder
                }
                return nil
            }
        }

        private func askForSignatureHelp() {
            guard let document = session?.document else { return }
            let text = source
            let position = caretPosition
            signatureRequest?.cancel()
            signatureRequest = Task { @MainActor in
                let help = try? await document.signatureHelp(at: position)
                guard !Task.isCancelled, source == text else { return }
                guard let help, !help.signatures.isEmpty else {
                    signature.dismiss()
                    return
                }
                signature.show(signatureText(help), key: caret, relativeTo: caretRect(), of: self, preferredEdge: .minY)
            }
        }

        private func signatureText(_ help: LSP.SignatureHelp) -> NSAttributedString {
            let active = help.signatures[min(help.activeSignature ?? 0, help.signatures.count - 1)]
            let activeParameter = active.activeParameter ?? help.activeParameter ?? 0
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            let text = NSMutableAttributedString(string: active.label, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            if let parameter = (active.parameters ?? []).indices.contains(activeParameter) ? active.parameters?[activeParameter] : nil,
                let range = parameterRange(parameter, in: active.label)
            {
                text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold), range: range)
                if let documentation = parameter.documentation?.text, !documentation.isEmpty {
                    text.append(NSAttributedString(string: "\n\n" + documentation, attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                }
            }
            return text
        }

        private func parameterRange(_ parameter: LSP.ParameterInformation, in label: String) -> NSRange? {
            switch parameter.label {
            case .offsets(let start, let end):
                return NSRange(location: start, length: min(end, label.utf16.count) - start)
            case .text(let text):
                let found = (label as NSString).range(of: text)
                return found.location == NSNotFound ? nil : found
            }
        }

        private func caretRect() -> NSRect {
            let screenRect = firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
            guard let window else { return .zero }
            return convert(window.convertFromScreen(screenRect), from: nil)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
            case (.command, "f"): find(.showFindInterface); return true
            case (.command, "e"): find(.setSearchString); return true
            case (.command, "g"): find(.nextMatch); return true
            case ([.command, .shift], "g"): find(.previousMatch); return true
            default: return super.performKeyEquivalent(with: event)
            }
        }

        private func find(_ action: NSTextFinder.Action) {
            let request = NSMenuItem()
            request.tag = action.rawValue
            performTextFinderAction(request)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self))
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            let point = convert(event.locationInWindow, from: nil)
            scheduleHover(at: characterIndexForInsertion(at: point))
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            hoverRequest?.cancel()
            hover.dismiss()
        }

        override func keyDown(with event: NSEvent) {
            hover.dismiss()
            super.keyDown(with: event)
        }

        private func scheduleHover(at offset: Int) {
            hoverRequest?.cancel()
            guard offset < storage.length else {
                hover.dismiss()
                return
            }
            if hover.isShowing(key: offset) { return }
            hover.dismiss()
            let work = DispatchWorkItem { [weak self] in self?.requestHover(at: offset) }
            hoverRequest = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        private func requestHover(at offset: Int) {
            let text = source
            let messages = diagnostics(atUTF16Offset: offset)
            guard let document = session?.document else {
                showHover(hoverText(messages: messages, segments: []), at: offset)
                return
            }
            let position = LineMap(text: text).position(ofUTF16Offset: offset)
            Task { @MainActor in
                let answer = try? await document.hover(at: position)
                guard self.source == text else { return }
                var segments: [(HoverMarkdown.Segment, [SemanticToken])] = []
                for segment in HoverMarkdown.segments(answer?.contents.text ?? "") {
                    segments.append((segment, segment.isCode ? await document.classify(segment.text) : []))
                }
                guard self.source == text else { return }
                showHover(hoverText(messages: messages, segments: segments), at: offset)
            }
        }

        private func hoverText(messages: [String], segments: [(HoverMarkdown.Segment, [SemanticToken])]) -> NSAttributedString {
            let font = PlatformFont.monospacedSystemFont(ofSize: PlatformFont.smallSystemFontSize, weight: .regular)
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let result = NSMutableAttributedString()
            func appendPlain(_ string: String) {
                result.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: PlatformColor.platformLabel]))
            }
            func separate() {
                if result.length > 0 { appendPlain("\n\n") }
            }
            for message in messages where !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                separate()
                appendPlain(message)
            }
            for (segment, tokens) in segments where !segment.text.isEmpty {
                separate()
                guard segment.isCode else {
                    appendPlain(segment.text)
                    continue
                }
                let units = Array(segment.text.utf16)
                for run in SourceHighlighter.runs(of: segment.text, semanticTokens: tokens, dark: dark) {
                    let piece = String(utf16CodeUnits: Array(units[run.range]), count: run.range.count)
                    let color = run.color.map(PlatformColor.init(rgb:)) ?? PlatformColor.platformLabel
                    result.append(NSAttributedString(string: piece, attributes: [.font: font, .foregroundColor: color]))
                }
            }
            return result
        }

        private func diagnostics(atUTF16Offset offset: Int) -> [String] {
            let lineMap = LineMap(text: source)
            return diagnostics
                .filter { lineMap.utf16Range(of: $0.range).contains(offset) || lineMap.utf16Offset(of: $0.range.start) == offset }
                .map(\.message)
        }

        private func showHover(_ text: NSAttributedString, at offset: Int) {
            guard text.length > 0, let layoutManager, let textContainer else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            hover.show(text, key: offset, relativeTo: rect, of: self, preferredEdge: .maxY)
        }
    #else
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocused?() }
            return became
        }

        override func insertText(_ text: String) {
            if text == "\n" {
                let selection = selectedRange
                let newline = SourceIndentation.newline(in: source, atUTF16: selection.location)
                storage.replaceCharacters(in: selection, with: newline.text)
                moveCaret(to: selection.location + newline.caretOffset)
                noteEdited()
                return
            }
            if text.utf16.count == 1, let unit = text.utf16.first, unit == 0x29 || unit == 0x5D || unit == 0x7D,
                selectedRange.length == 0, let dedent = SourceIndentation.closerDedent(in: source, atUTF16: caret)
            {
                storage.replaceCharacters(in: NSRange(location: dedent.lowerBound, length: dedent.count), with: "")
                moveCaret(to: dedent.lowerBound)
            }
            super.insertText(text)
            guard text.utf16.count == 1, let unit = text.utf16.first else { return }
            if isWordUnit(unit) {
                askForCompletions(trigger: nil)
            } else if text == "." {
                askForCompletions(trigger: ".")
            }
        }

        override func deleteBackward() {
            if selectedRange.length == 0, let dedent = SourceIndentation.backspaceDedent(in: source, atUTF16: caret) {
                storage.replaceCharacters(in: NSRange(location: dedent.lowerBound, length: dedent.count), with: "")
                moveCaret(to: dedent.lowerBound)
                noteEdited()
                return
            }
            super.deleteBackward()
        }

        private func offerCompletions() {
            let matching = matchingCandidates()
            candidates.offer(matching.map(\.label)) { [weak self] word in
                guard let self, let item = matching.first(where: { $0.label == word }) else { return }
                let range = self.completionWordRange
                let text = self.isCallable(item) ? CallTemplate(name: self.insertion(for: item), parameters: []).text : self.insertion(for: item)
                self.replace(range, with: text)
                self.moveCaret(to: range.location + text.utf16.count)
            }
            guard inputAccessoryView == nil, !matching.isEmpty else { return }
            let bar = PlatformHostingView(rootView: CompletionStrip(candidates: candidates))
            bar.frame.size.height = completionBarHeight
            bar.autoresizingMask = .flexibleWidth
            inputAccessoryView = bar
            reloadInputViews()
        }
    #endif
}

enum CodeSnippetText {
    static func plain(_ snippet: String) -> String {
        var result = ""
        var index = snippet.startIndex
        while index < snippet.endIndex {
            let character = snippet[index]
            if character == "\\", snippet.index(after: index) < snippet.endIndex {
                index = snippet.index(after: index)
                result.append(snippet[index])
            } else if character == "$" {
                index = skipPlaceholder(in: snippet, from: index, into: &result)
                continue
            } else {
                result.append(character)
            }
            index = snippet.index(after: index)
        }
        return result
    }

    private static func skipPlaceholder(in snippet: String, from dollar: String.Index, into result: inout String) -> String.Index {
        var index = snippet.index(after: dollar)
        guard index < snippet.endIndex else { return index }
        if snippet[index] == "{" {
            var depth = 1
            var body = ""
            index = snippet.index(after: index)
            while index < snippet.endIndex, depth > 0 {
                let character = snippet[index]
                if character == "{" { depth += 1 }
                if character == "}" { depth -= 1 }
                if depth > 0 { body.append(character) }
                index = snippet.index(after: index)
            }
            if let colon = body.firstIndex(of: ":") {
                result += plain(String(body[body.index(after: colon)...]))
            }
            return index
        }
        while index < snippet.endIndex, snippet[index].isNumber {
            index = snippet.index(after: index)
        }
        return index
    }
}

extension Optional where Wrapped: RangeReplaceableCollection {
    var orEmpty: Wrapped {
        self ?? Wrapped()
    }
}

extension PlatformColor {
    static func syntaxRun(light: LumaCore.RGBColor, dark: LumaCore.RGBColor) -> PlatformColor {
        #if canImport(AppKit)
            return NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light)
            }
        #else
            return UIColor { trait in
                UIColor(rgb: trait.userInterfaceStyle == .dark ? dark : light)
            }
        #endif
    }

    convenience init(rgb: LumaCore.RGBColor) {
        let red = CGFloat(rgb.r) / 255
        let green = CGFloat(rgb.g) / 255
        let blue = CGFloat(rgb.b) / 255
        #if canImport(AppKit)
            self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
        #else
            self.init(red: red, green: green, blue: blue, alpha: 1)
        #endif
    }
}

#if canImport(AppKit)
    @MainActor
    final class CodeInfoPopover {
        private let popover = NSPopover()
        private var key: Int?

        init() {
            popover.behavior = .transient
            popover.animates = false
        }

        var isShown: Bool {
            popover.isShown
        }

        func isShowing(key: Int) -> Bool {
            popover.isShown && self.key == key
        }

        func show(_ text: NSAttributedString, key: Int, relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
            let label = NSTextField(wrappingLabelWithString: "")
            label.attributedStringValue = text
            label.preferredMaxLayoutWidth = 480
            let size = label.fittingSize
            label.frame = NSRect(x: 10, y: 8, width: ceil(size.width), height: ceil(size.height))
            let padded = NSView(frame: NSRect(x: 0, y: 0, width: ceil(size.width) + 20, height: ceil(size.height) + 16))
            padded.addSubview(label)
            let controller = NSViewController()
            controller.view = padded
            popover.contentSize = padded.frame.size
            popover.contentViewController = controller
            self.key = key
            popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
        }

        func dismiss() {
            guard popover.isShown else { return }
            popover.performClose(nil)
            key = nil
        }
    }
#endif
