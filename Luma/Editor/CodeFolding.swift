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

    nonisolated final class FoldingLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
        static let swatchSize: CGFloat = 10
        static let swatchGap: CGFloat = 4
        static let placeholderWidth: CGFloat = 22
        static let placeholderGap: CGFloat = 3
        static let placeholderKern = placeholderWidth + placeholderGap * 2

        override init() {
            super.init()
            delegate = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("FoldingLayoutManager is not loaded from a nib")
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldUse action: NSLayoutManager.ControlCharacterAction,
            forControlCharacterAt charIndex: Int
        ) -> NSLayoutManager.ControlCharacterAction {
            isHidden(charIndex) ? .zeroAdvancement : action
        }

        var hiddenRanges: [NSRange] = [] {
            didSet {
                guard hiddenRanges != oldValue else { return }
                invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0), changeInLength: 0, actualCharacterRange: nil)
                invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0), actualCharacterRange: nil)
            }
        }

        var swatches: [CodeSwatch] = []

        private(set) var placeholderRects: [(rect: NSRect, hidden: NSRange)] = []

        override func setGlyphs(
            _ glyphs: UnsafePointer<CGGlyph>,
            properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes: UnsafePointer<Int>,
            font: NSFont,
            forGlyphRange glyphRange: NSRange
        ) {
            guard !hiddenRanges.isEmpty else {
                super.setGlyphs(glyphs, properties: properties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
                return
            }
            var adjusted = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
            for index in 0..<glyphRange.length where isHidden(characterIndexes[index]) {
                adjusted[index] = .null
            }
            adjusted.withUnsafeBufferPointer { buffer in
                super.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            }
        }

        override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            drawPlaceholders(at: origin)
            drawSwatches(at: origin)
        }

        private func drawPlaceholders(at origin: NSPoint) {
            placeholderRects = []
            guard let length = textStorage?.length else { return }
            let label = NSAttributedString(string: "\u{22EF}", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let labelSize = label.size()
            for hidden in hiddenRanges where hidden.location > 0 && NSMaxRange(hidden) < length {
                let resumed = glyphIndexForCharacter(at: NSMaxRange(hidden))
                let line = lineFragmentRect(forGlyphAt: resumed, effectiveRange: nil)
                let resumedX = line.minX + location(forGlyphAt: resumed).x
                let pill = NSRect(
                    x: origin.x + resumedX - Self.placeholderGap - Self.placeholderWidth,
                    y: origin.y + line.midY - labelSize.height / 2 - 1,
                    width: Self.placeholderWidth, height: labelSize.height + 2
                ).integral
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
                label.draw(at: NSPoint(x: pill.midX - labelSize.width / 2, y: pill.minY + 1))
                placeholderRects.append((pill, hidden))
            }
        }

        private func drawSwatches(at origin: NSPoint) {
            guard let container = textContainers.first, let length = textStorage?.length else { return }
            for swatch in swatches where swatch.location < length && !isHidden(swatch.location) {
                let glyph = glyphIndexForCharacter(at: swatch.location)
                let rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                let side = Self.swatchSize
                let square = NSRect(x: rect.minX + origin.x - side - Self.swatchGap / 2, y: rect.midY + origin.y - side / 2, width: side, height: side)
                swatch.color.setFill()
                NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2).fill()
                NSColor.separatorColor.setStroke()
                NSBezierPath(roundedRect: square.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            }
        }

        func isHidden(_ characterIndex: Int) -> Bool {
            hiddenRanges.contains { NSLocationInRange(characterIndex, $0) }
        }
    }

    enum ScopeGuides {
        static let color = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.827, alpha: 1)
        }

        static func draw(_ scopes: [LSP.FoldingRange], in textView: NSTextView, dirtyRect: NSRect) {
            guard let layoutManager = textView.layoutManager as? FoldingLayoutManager else { return }
            let text = textView.string as NSString
            let lines = LineMap(text: textView.string)
            let origin = textView.textContainerOrigin
            color.setFill()
            for scope in scopes where scope.kind == nil && scope.endLine - scope.startLine >= 2 {
                let opening = lines.utf16Offset(of: LSP.Position(line: scope.startLine, character: 0))
                let firstInside = lines.utf16Offset(of: LSP.Position(line: scope.startLine + 1, character: 0))
                let lastInside = lines.utf16Offset(of: LSP.Position(line: scope.endLine - 1, character: 0))
                guard lastInside < text.length, !layoutManager.isHidden(firstInside) else { continue }
                let indent = firstNonBlank(in: text, from: opening)
                let indentGlyph = layoutManager.glyphIndexForCharacter(at: indent)
                let openingFragment = layoutManager.lineFragmentRect(forGlyphAt: indentGlyph, effectiveRange: nil)
                let x = origin.x + openingFragment.minX + layoutManager.location(forGlyphAt: indentGlyph).x
                    + inkOffset(ofGlyph: indentGlyph, character: indent, in: layoutManager)
                let top = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: firstInside), effectiveRange: nil).minY
                let bottom = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: lastInside), effectiveRange: nil).maxY
                let guide = textView.backingAlignedRect(
                    NSRect(x: x, y: origin.y + top, width: 1, height: bottom - top), options: .alignAllEdgesNearest)
                if guide.intersects(dirtyRect) {
                    guide.fill()
                }
            }
        }

        private static func inkOffset(ofGlyph glyph: Int, character: Int, in layoutManager: NSLayoutManager) -> CGFloat {
            guard let font = layoutManager.textStorage?.attribute(.font, at: character, effectiveRange: nil) as? NSFont else { return 0 }
            return font.boundingRect(forCGGlyph: layoutManager.cgGlyph(at: glyph)).minX
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

        static func rect(in textView: NSTextView, font: NSFont) -> NSRect? {
            let selection = textView.selectedRange()
            guard selection.length == 0, let layoutManager = textView.layoutManager else { return nil }
            let length = (textView.string as NSString).length
            let fragment: NSRect
            if selection.location >= length, !layoutManager.extraLineFragmentRect.isEmpty {
                fragment = layoutManager.extraLineFragmentRect
            } else if length > 0 {
                let glyph = layoutManager.glyphIndexForCharacter(at: min(selection.location, length - 1))
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                return nil
            }
            let band = NSRect(
                x: 0, y: fragment.minY + textView.textContainerOrigin.y + capsCentering(in: fragment, font: font, layoutManager: layoutManager),
                width: textView.bounds.width, height: fragment.height)
            return textView.backingAlignedRect(band, options: .alignAllEdgesNearest)
        }

        private static func capsCentering(in fragment: NSRect, font: NSFont, layoutManager: NSLayoutManager) -> CGFloat {
            let baseline = layoutManager.defaultBaselineOffset(for: font)
            let spaceAboveCaps = baseline - font.capHeight
            let spaceBelowBaseline = fragment.height - baseline
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
            guard let layoutManager = textView.layoutManager as? FoldingLayoutManager else { return [] }
            let text = textView.string as NSString
            let origin = textView.textContainerOrigin
            var rows: [Row] = []
            var line = 0
            var index = 0
            let baselineOffset = layoutManager.defaultBaselineOffset(for: sourceFont)
            var previousTop: CGFloat?
            while true {
                let fragment: NSRect
                if index < text.length {
                    fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: index), effectiveRange: nil)
                } else if !layoutManager.extraLineFragmentRect.isEmpty {
                    fragment = layoutManager.extraLineFragmentRect
                } else {
                    break
                }
                let top = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
                let isShown = !layoutManager.isHidden(index) || index == 0
                if isShown, top != previousTop, top + fragment.height >= 0, top <= bounds.height {
                    rows.append(Row(line: line, top: top, height: fragment.height, baseline: top + baselineOffset))
                }
                if isShown {
                    previousTop = top
                }
                guard index < text.length else { break }
                index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
                line += 1
                if index == text.length, text.character(at: text.length - 1) != 0x0A { break }
            }
            return rows
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
