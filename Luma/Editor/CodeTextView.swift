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
    var onCaretMove: ((LSP.Position) -> Void)?
    var sourceFont = PlatformFont.monospacedSystemFont(ofSize: PlatformFont.systemFontSize, weight: .regular) {
        didSet {
            restyle()
            #if canImport(AppKit)
                onLineStateChanged?()
            #endif
        }
    }

    var session: TypeScriptEditorSession? {
        didSet { bindSession() }
    }

    var syntax: SourceSyntax = .typeScript {
        didSet {
            if oldValue != syntax { restyle() }
        }
    }

    #if canImport(AppKit)
        var onLineStateChanged: (() -> Void)?
        let folding = FoldedParagraphs()

        private var foldable: [LSP.FoldingRange] = []
        private var folds: [CodeFold] = []
        private var foldsDroppedByEdit = false
        private var colors: [LSP.ColorInformation] = []
        private var swatches: [CodeSwatch] = []
        private var placeholderTargets: [(rect: NSRect, fold: CodeFold)] = []
    #endif

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
        private var completionWordStart = 0

        static func make() -> CodeTextView {
            let view = CodeTextView(usingTextLayoutManager: true)
            view.textContentStorage!.delegate = view.folding
            return view
        }
    #else
        private let candidates = CompletionCandidates()
        private let completionBarHeight: CGFloat = 38

        static func make() -> CodeTextView {
            CodeTextView(usingTextLayoutManager: true)
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
        #if canImport(AppKit)
            onLineStateChanged?()
        #endif
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
        #if canImport(AppKit)
            session.document.onFoldingRanges = { [weak self] ranges in
                self?.updateFoldable(ranges)
            }
            session.document.onColors = { [weak self] colors in
                self?.colors = colors
                self?.restyle()
            }
        #endif
    }

    func noteCaretMoved() {
        onCaretMove?(caretPosition)
    }

    func noteEdited() {
        guard !isReplacingSource else { return }
        let text = source
        restyle()
        #if canImport(AppKit)
            onLineStateChanged?()
        #endif
        session?.document.replaceText(text)
        onEdit?(text)
    }

    private func restyle() {
        let text = source
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        let plain: [NSAttributedString.Key: Any] = [.font: sourceFont, .foregroundColor: PlatformColor.platformLabel]
        storage.setAttributes(plain, range: whole)
        typingAttributes = plain
        for token in syntax.tokenize(text) {
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
        #if canImport(AppKit)
            swatches = []
            for color in colors {
                let range = lineMap.utf16Range(of: color.range)
                guard range.lowerBound > 0, range.lowerBound <= storage.length else { continue }
                storage.addAttribute(
                    .kern, value: ColorSwatches.size + ColorSwatches.gap,
                    range: NSRange(location: range.lowerBound - 1, length: 1))
                swatches.append(CodeSwatch(location: range.lowerBound, color: NSColor(color.color)))
            }
        #endif
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
            hideFoldedParagraphs(relayout: foldsDroppedByEdit)
            foldsDroppedByEdit = false
            noteEdited()
        }

        override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
            if allowed {
                let replacementLength = (replacementString ?? "").utf16.count
                shiftPlaceholders(for: affectedCharRange, replacementLength: replacementLength)
                shiftFolds(for: affectedCharRange, replacementLength: replacementLength)
            }
            return allowed
        }

        override func drawBackground(in rect: NSRect) {
            super.drawBackground(in: rect)
            if let band = CurrentLineBand.rect(in: self, font: sourceFont), band.intersects(rect) {
                CurrentLineBand.color.setFill()
                band.fill()
            }
            let folded = foldedStartLines
            ScopeGuides.draw(foldable.filter { !folded.contains($0.startLine) }, in: self, dirtyRect: rect)
            placeholderTargets = FoldPlaceholders.draw(folds, in: self)
            ColorSwatches.draw(swatches, in: self)
        }

        override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
            setNeedsDisplay(visibleRect)
            onLineStateChanged?()
            noteCaretMoved()
        }

        override func mouseDown(with event: NSEvent) {
            completionPanel.dismiss()
            let point = convert(event.locationInWindow, from: nil)
            if let hit = placeholderTargets.first(where: { $0.rect.contains(point) }) {
                folds.removeAll { $0 == hit.fold }
                applyFolds()
                return
            }
            super.mouseDown(with: event)
        }

        var foldableStartLines: Set<Int> {
            Set(foldable.map(\.startLine))
        }

        var foldedStartLines: Set<Int> {
            Set(folds.map(\.startLine))
        }

        func toggleFold(atLine line: Int) {
            if let index = folds.firstIndex(where: { $0.startLine == line }) {
                folds.remove(at: index)
            } else if let fold = CodeFold.folds(from: foldable.filter { $0.startLine == line }, in: source).first {
                folds.append(fold)
            }
            applyFolds()
        }

        func reveal(_ range: LSP.Range) {
            let target = LineMap(text: source).utf16Range(of: range)
            folds.removeAll { NSIntersectionRange($0.hidden, NSRange(location: target.lowerBound, length: max(target.count, 1))).length > 0 || NSLocationInRange(target.lowerBound, $0.hidden) }
            applyFolds()
            let selection = NSRange(location: target.lowerBound, length: target.count)
            setSelectedRange(selection)
            scrollRangeToVisible(selection)
            window?.makeFirstResponder(self)
        }

        private func updateFoldable(_ ranges: [LSP.FoldingRange]) {
            foldable = ranges.filter { $0.endLine > $0.startLine }
            let kept = foldedStartLines
            folds = CodeFold.folds(from: ranges.filter { kept.contains($0.startLine) }, in: source)
            applyFolds()
        }

        private func shiftFolds(for edited: NSRange, replacementLength: Int) {
            let delta = replacementLength - edited.length
            let previousCount = folds.count
            folds = folds.compactMap { fold in
                let touchesHidden = NSIntersectionRange(edited, fold.hidden).length > 0 || NSLocationInRange(edited.location, fold.hidden)
                if touchesHidden { return nil }
                guard fold.hidden.location >= NSMaxRange(edited) else { return fold }
                return CodeFold(startLine: fold.startLine, hidden: NSRange(location: fold.hidden.location + delta, length: fold.hidden.length))
            }
            foldsDroppedByEdit = foldsDroppedByEdit || folds.count != previousCount
        }

        private func applyFolds() {
            hideFoldedParagraphs(relayout: true)
            restyle()
            needsDisplay = true
            onLineStateChanged?()
        }

        private func hideFoldedParagraphs(relayout: Bool) {
            let text = string as NSString
            folding.ranges = folds.map { $0.hiddenParagraphs(in: text) }
            if relayout {
                textLayoutManager!.invalidateLayout(for: textLayoutManager!.documentRange)
            }
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
            } else {
                super.deleteBackward(sender)
            }
            refilterCompletionsAfterDeletion()
        }

        private func refilterCompletionsAfterDeletion() {
            guard completionPanel.isShown else { return }
            let word = completionWordRange
            let isSameWord = word.location == completionWordStart
            let followsMemberAccess = word.location > 0 && (source as NSString).character(at: word.location - 1) == 0x2E
            guard isSameWord, word.length > 0 || followsMemberAccess else {
                completionPanel.dismiss()
                return
            }
            offerCompletions()
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
            completionWordStart = completionWordRange.location
            let anchor = firstRect(forCharacterRange: NSRange(location: completionWordStart, length: 0), actualRange: nil)
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
            guard text.length > 0, let rect = characterFrame(at: offset) else { return }
            hover.show(text, key: offset, relativeTo: rect, of: self, preferredEdge: .maxY)
        }

        struct LineBox {
            let frame: NSRect
            let baseline: CGFloat
        }

        func lineBox(at offset: Int) -> LineBox? {
            guard offset < (string as NSString).length else { return lastLineBox() }
            let layout = textLayoutManager!
            guard let fragment = layout.textLayoutFragment(for: location(atOffset: offset)),
                let line = fragment.textLineFragments.first
            else { return nil }
            return box(of: line, in: fragment)
        }

        func lineBoxes(from minY: CGFloat, through maxY: CGFloat) -> [(line: Int, box: LineBox)] {
            let layout = textLayoutManager!
            let content = textContentStorage!
            let text = string as NSString
            let top = CGPoint(x: 0, y: max(minY - textContainerOrigin.y, 0))
            let start = layout.textLayoutFragment(for: top)?.rangeInElement.location ?? layout.documentRange.location
            var boxes: [(line: Int, box: LineBox)] = []
            var line = 0
            var counted = 0
            layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
                let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
                line += Self.newlineCount(in: text, from: counted, to: offset)
                counted = offset
                for (index, lineFragment) in fragment.textLineFragments.enumerated() {
                    boxes.append((line + index, box(of: lineFragment, in: fragment)))
                }
                return fragment.layoutFragmentFrame.maxY + textContainerOrigin.y < maxY
            }
            return boxes
        }

        func characterFrame(at offset: Int) -> NSRect? {
            let end = min(offset + 1, (string as NSString).length)
            return segmentFrame(of: NSTextRange(location: location(atOffset: offset), end: location(atOffset: end)))
        }

        func caretFrame(at offset: Int) -> NSRect? {
            segmentFrame(of: NSTextRange(location: location(atOffset: offset)))
        }

        private func lastLineBox() -> LineBox? {
            let layout = textLayoutManager!
            var last: LineBox?
            layout.enumerateTextLayoutFragments(from: layout.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { fragment in
                last = fragment.textLineFragments.last.map { box(of: $0, in: fragment) }
                return false
            }
            return last
        }

        private func box(of line: NSTextLineFragment, in fragment: NSTextLayoutFragment) -> LineBox {
            let origin = fragment.layoutFragmentFrame.origin
            let frame = line.typographicBounds.offsetBy(dx: origin.x + textContainerOrigin.x, dy: origin.y + textContainerOrigin.y)
            return LineBox(frame: frame, baseline: frame.minY + line.glyphOrigin.y)
        }

        private func segmentFrame(of range: NSTextRange?) -> NSRect? {
            guard let range else { return nil }
            var frame: NSRect?
            textLayoutManager!.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
                frame = frame?.union(segment) ?? segment
                return true
            }
            return frame?.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }

        private func location(atOffset offset: Int) -> NSTextLocation {
            let content = textContentStorage!
            return content.location(content.documentRange.location, offsetBy: offset)!
        }

        private static func newlineCount(in text: NSString, from start: Int, to end: Int) -> Int {
            var count = 0
            for index in start..<end where text.character(at: index) == 0x0A {
                count += 1
            }
            return count
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
