import LumaCore

#if canImport(AppKit)
    import AppKit

    struct CodeFold: Hashable {
        let startLine: Int
        let hidden: NSRange

        static func folds(from ranges: [LSP.FoldingRange], in text: String) -> [CodeFold] {
            let map = LineMap(text: text)
            let units = Array(text.utf16)
            return ranges.compactMap { range in
                var start = map.utf16Offset(of: LSP.Position(line: range.startLine, character: range.startCharacter ?? 0))
                var end = map.utf16Offset(of: LSP.Position(line: range.endLine, character: range.endCharacter ?? 0))
                if range.startCharacter == nil {
                    start = map.utf16Offset(of: LSP.Position(line: range.startLine + 1, character: 0)) - 1
                }
                if range.endCharacter == nil {
                    end = map.utf16Offset(of: LSP.Position(line: range.endLine + 1, character: 0)) - 1
                }
                if start < units.count, Self.openers.contains(units[start]) {
                    start += 1
                }
                if end > 0, end <= units.count, Self.closers.contains(units[end - 1]) {
                    end -= 1
                }
                guard end > start else { return nil }
                return CodeFold(startLine: range.startLine, hidden: NSRange(location: start, length: end - start))
            }
        }

        func hiddenParagraphs(in text: NSString) -> NSRange {
            let firstHidden = NSMaxRange(text.lineRange(for: NSRange(location: hidden.location, length: 0)))
            let closingLine = text.lineRange(for: NSRange(location: NSMaxRange(hidden), length: 0))
            return NSRange(location: firstHidden, length: closingLine.location - firstHidden)
        }

        func visibleEndOfFirstLine(in text: NSString) -> Int {
            Self.contentEnd(ofLineRange: text.lineRange(for: NSRange(location: hidden.location, length: 0)), in: text)
        }

        private static func contentEnd(ofLineRange line: NSRange, in text: NSString) -> Int {
            var end = NSMaxRange(line)
            while end > line.location, text.character(at: end - 1) == 0x0A || text.character(at: end - 1) == 0x0D {
                end -= 1
            }
            return end
        }

        private static let openers: Set<UTF16.CodeUnit> = [0x7B, 0x28, 0x5B]
        private static let closers: Set<UTF16.CodeUnit> = [0x7D, 0x29, 0x5D]
    }

    extension NSColor {
        convenience init(_ color: LSP.Color) {
            self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        }
    }

    struct CodeSwatch: Hashable {
        let location: Int
        let color: NSColor
    }

    nonisolated final class FoldedParagraphs: NSObject, NSTextContentStorageDelegate {
        var ranges: [NSRange] = []

        func textContentManager(
            _ textContentManager: NSTextContentManager,
            shouldEnumerate textElement: NSTextElement,
            options: NSTextContentManager.EnumerationOptions
        ) -> Bool {
            guard let start = textElement.elementRange?.location else { return true }
            return !hides(textContentManager.offset(from: textContentManager.documentRange.location, to: start))
        }

        func hides(_ characterIndex: Int) -> Bool {
            ranges.contains { NSLocationInRange(characterIndex, $0) }
        }
    }

    enum FoldPlaceholders {
        static let width: CGFloat = 22
        static let gap: CGFloat = 3

        static func draw(_ folds: [CodeFold], in textView: CodeTextView) -> [(rect: NSRect, fold: CodeFold)] {
            let text = textView.string as NSString
            let label = NSAttributedString(string: "\u{22EF}", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let labelSize = label.size()
            var targets: [(rect: NSRect, fold: CodeFold)] = []
            for fold in folds {
                let visibleEnd = fold.visibleEndOfFirstLine(in: text)
                guard let line = textView.lineBox(at: visibleEnd),
                    let end = textView.caretFrame(at: visibleEnd)
                else { continue }
                let pill = NSRect(
                    x: end.minX + gap, y: line.frame.midY - labelSize.height / 2 - 1,
                    width: width, height: labelSize.height + 2
                ).integral
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
                label.draw(at: NSPoint(x: pill.midX - labelSize.width / 2, y: pill.minY + 1))
                targets.append((pill, fold))
            }
            return targets
        }
    }

    enum ColorSwatches {
        static let size: CGFloat = 10
        static let gap: CGFloat = 4

        static func draw(_ swatches: [CodeSwatch], in textView: CodeTextView) {
            for swatch in swatches where !textView.folding.hides(swatch.location) {
                guard let glyph = textView.characterFrame(at: swatch.location) else { continue }
                let square = NSRect(x: glyph.minX - size - gap / 2, y: glyph.midY - size / 2, width: size, height: size)
                swatch.color.setFill()
                NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2).fill()
                NSColor.separatorColor.setStroke()
                NSBezierPath(roundedRect: square.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            }
        }
    }

    enum ScopeGuides {
        static let color = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.827, alpha: 1)
        }

        static func draw(_ scopes: [LSP.FoldingRange], in textView: CodeTextView, dirtyRect: NSRect) {
            var boxes: [Int: CodeTextView.LineBox] = [:]
            for (line, box) in textView.lineBoxes(from: dirtyRect.minY, through: dirtyRect.maxY) where boxes[line] == nil {
                boxes[line] = box
            }
            guard let firstVisible = boxes.keys.min(), let lastVisible = boxes.keys.max() else { return }
            let text = textView.string as NSString
            let lines = LineMap(text: textView.string)
            color.setFill()
            for scope in scopes
            where scope.kind == nil && scope.endLine - scope.startLine >= 2 && scope.startLine < lastVisible && scope.endLine > firstVisible {
                let opening = lines.utf16Offset(of: LSP.Position(line: scope.startLine, character: 0))
                let firstInside = lines.utf16Offset(of: LSP.Position(line: scope.startLine + 1, character: 0))
                let lastInside = lines.utf16Offset(of: LSP.Position(line: scope.endLine - 1, character: 0))
                guard lastInside < text.length, !textView.folding.hides(firstInside) else { continue }
                let indent = firstNonBlank(in: text, from: opening)
                guard let indentFrame = textView.characterFrame(at: indent) else { continue }
                let top = boxes[scope.startLine + 1]?.frame.minY ?? dirtyRect.minY
                let bottom = boxes[scope.endLine - 1]?.frame.maxY ?? dirtyRect.maxY
                let x = indentFrame.minX + inkOffset(ofCharacterAt: indent, in: textView.textStorage!)
                let guide = textView.backingAlignedRect(
                    NSRect(x: x, y: top, width: 1, height: bottom - top), options: .alignAllEdgesNearest)
                guide.fill()
            }
        }

        private static func inkOffset(ofCharacterAt index: Int, in storage: NSTextStorage) -> CGFloat {
            guard let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont else { return 0 }
            var character = (storage.string as NSString).character(at: index)
            var glyph = CGGlyph()
            CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
            return font.boundingRect(forCGGlyph: glyph).minX
        }

        private static func firstNonBlank(in text: NSString, from start: Int) -> Int {
            var index = start
            while index < text.length, text.character(at: index) == 0x20 || text.character(at: index) == 0x09 {
                index += 1
            }
            return index
        }
    }

    enum CurrentLineBand {
        static let color = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.07)
        }

        static func rect(in textView: CodeTextView, font: NSFont) -> NSRect? {
            let selection = textView.selectedRange()
            guard selection.length == 0, let line = textView.lineBox(at: selection.location) else { return nil }
            let band = NSRect(
                x: 0, y: line.frame.minY + capsCentering(in: line, font: font),
                width: textView.bounds.width, height: line.frame.height)
            return textView.backingAlignedRect(band, options: .alignAllEdgesNearest)
        }

        private static func capsCentering(in line: CodeTextView.LineBox, font: NSFont) -> CGFloat {
            let baseline = line.baseline - line.frame.minY
            let spaceAboveCaps = baseline - font.capHeight
            let spaceBelowBaseline = line.frame.height - baseline
            return (spaceAboveCaps - spaceBelowBaseline) / 2
        }
    }

    final class CodeGutterView: NSRulerView {
        var onToggleFold: ((Int) -> Void)?

        var showsOpenFoldControls = false {
            didSet {
                guard showsOpenFoldControls != oldValue else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = showsOpenFoldControls ? 0.15 : 0.4
                    openFoldControls.animator().alphaValue = showsOpenFoldControls ? 1 : 0
                }
            }
        }

        private let textView: CodeTextView
        private let openFoldControls = OpenFoldControlsView()
        private var foldTargets: [(rect: NSRect, line: Int)] = []
        private var digitCount = 0
        private var sizedAdvance: CGFloat = 0

        private static let leadingInset: CGFloat = 18
        private static let bandInset: CGFloat = 4
        private static let numberToChevron: CGFloat = 1.26
        private static let chevronWidth: CGFloat = 1.41
        private static let chevronHeight: CGFloat = 0.72
        private static let chevronStroke: CGFloat = 0.2
        private static let chevronToCode: CGFloat = 0.55
        private static let chevronDrop: CGFloat = 0.5

        init(scrollView: NSScrollView, textView: CodeTextView) {
            self.textView = textView
            super.init(scrollView: scrollView, orientation: .verticalRuler)
            clientView = textView
            clipsToBounds = true
            openFoldControls.frame = bounds
            openFoldControls.autoresizingMask = [.width, .height]
            openFoldControls.wantsLayer = true
            openFoldControls.alphaValue = 0
            addSubview(openFoldControls)
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("CodeGutterView is not loaded from a nib")
        }

        func refresh() {
            let digits = max(2, String(lineCount).count)
            if digits != digitCount || advance != sizedAdvance {
                digitCount = digits
                sizedAdvance = advance
                let textStart = textView.textContainerInset.width + (textView.textContainer?.lineFragmentPadding ?? 0)
                let chevronToText = max(Self.chevronToCode * advance - textStart, 0)
                let previousThickness = ruleThickness
                ruleThickness = (chevronColumnMinX + Self.chevronWidth * advance + chevronToText).rounded(.up)
                keepTextClear(ofPreviousThickness: previousThickness)
            }
            needsDisplay = true
        }

        private func keepTextClear(ofPreviousThickness previousThickness: CGFloat) {
            guard let scrollView, scrollView.verticalRulerView === self else { return }
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            origin.x = origin.x <= 0 ? -ruleThickness : origin.x - (ruleThickness - previousThickness)
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }

        override func resetCursorRects() {
            for target in foldTargets {
                addCursorRect(target.rect, cursor: .pointingHand)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            showsOpenFoldControls = true
        }

        override func mouseExited(with event: NSEvent) {
            showsOpenFoldControls = false
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let hit = foldTargets.first(where: { $0.rect.contains(point) }) else { return }
            onToggleFold?(hit.line)
        }

        override func drawHashMarksAndLabels(in rect: NSRect) {
            NSColor.textBackgroundColor.setFill()
            rect.fill()
            if let band = CurrentLineBand.rect(in: textView, font: sourceFont) {
                let top = convert(NSPoint(x: 0, y: band.minY), from: textView).y
                let x = Self.leadingInset - Self.bandInset
                CurrentLineBand.color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: top, width: bounds.width - x + 8, height: band.height), xRadius: 4, yRadius: 4).fill()
            }

            let foldable = textView.foldableStartLines
            let folded = textView.foldedStartLines
            let currentLine = caretLine
            var openChevrons: [FoldChevron] = []
            var targets: [(rect: NSRect, line: Int)] = []
            for row in visibleRows() {
                drawNumber(row.line + 1, baseline: row.baseline, isCurrent: row.line == currentLine)
                guard foldable.contains(row.line) else { continue }
                let chevron = FoldChevron(center: NSPoint(x: chevronCenterX, y: row.top + row.height / 2 + Self.chevronDrop), advance: advance)
                if folded.contains(row.line) {
                    chevron.draw(folded: true)
                } else {
                    openChevrons.append(chevron)
                }
                let cellMinX = chevronColumnMinX - Self.numberToChevron * advance / 2
                targets.append((NSRect(x: cellMinX, y: row.top, width: bounds.width - cellMinX, height: row.height), row.line))
            }
            openFoldControls.chevrons = openChevrons
            if !targets.elementsEqual(foldTargets, by: { $0.rect == $1.rect && $0.line == $1.line }) {
                foldTargets = targets
                window?.invalidateCursorRects(for: self)
            }
        }

        private struct Row {
            let line: Int
            let top: CGFloat
            let height: CGFloat
            let baseline: CGFloat
        }

        private func visibleRows() -> [Row] {
            let visible = convert(bounds, to: textView)
            return textView.lineBoxes(from: visible.minY, through: visible.maxY).map { line, box in
                let top = convert(NSPoint(x: 0, y: box.frame.minY), from: textView).y
                return Row(line: line, top: top, height: box.frame.height, baseline: top + box.baseline - box.frame.minY)
            }
        }

        private func drawNumber(_ number: Int, baseline: CGFloat, isCurrent: Bool) {
            let label = NSAttributedString(string: String(number), attributes: [
                .font: sourceFont,
                .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ])
            let width = label.size().width
            label.draw(at: NSPoint(x: Self.leadingInset + numbersWidth - width, y: baseline - sourceFont.ascender))
        }

        private var chevronColumnMinX: CGFloat {
            Self.leadingInset + numbersWidth + Self.numberToChevron * advance
        }

        private var chevronCenterX: CGFloat {
            chevronColumnMinX + Self.chevronWidth * advance / 2
        }

        fileprivate struct FoldChevron: Equatable {
            let center: NSPoint
            let advance: CGFloat

            static let color = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.77, alpha: 1) : NSColor(white: 0.38, alpha: 1)
            }

            func draw(folded: Bool) {
                let stroke = CodeGutterView.chevronStroke * advance
                let halfSpan = (CodeGutterView.chevronWidth * advance - stroke) / 2
                let halfDepth = (CodeGutterView.chevronHeight * advance - stroke) / 2
                let path = NSBezierPath()
                if folded {
                    path.move(to: NSPoint(x: center.x - halfDepth, y: center.y - halfSpan))
                    path.line(to: NSPoint(x: center.x + halfDepth, y: center.y))
                    path.line(to: NSPoint(x: center.x - halfDepth, y: center.y + halfSpan))
                } else {
                    path.move(to: NSPoint(x: center.x - halfSpan, y: center.y - halfDepth))
                    path.line(to: NSPoint(x: center.x, y: center.y + halfDepth))
                    path.line(to: NSPoint(x: center.x + halfSpan, y: center.y - halfDepth))
                }
                path.lineWidth = stroke
                path.lineJoinStyle = .miter
                path.lineCapStyle = .butt
                Self.color.setStroke()
                path.stroke()
            }
        }

        private var caretLine: Int? {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return nil }
            let prefix = (textView.string as NSString).substring(to: min(selection.location, (textView.string as NSString).length))
            return prefix.utf16.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }

        private var lineCount: Int {
            textView.string.utf16.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        }

        private var numbersWidth: CGFloat {
            CGFloat(digitCount) * advance
        }

        private var advance: CGFloat {
            ("0" as NSString).size(withAttributes: [.font: sourceFont]).width
        }

        private var sourceFont: NSFont {
            textView.sourceFont
        }
    }

    private final class OpenFoldControlsView: NSView {
        var chevrons: [CodeGutterView.FoldChevron] = [] {
            didSet {
                if chevrons != oldValue { needsDisplay = true }
            }
        }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            for chevron in chevrons {
                chevron.draw(folded: false)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
#endif
