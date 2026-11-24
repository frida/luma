import Gtk
import SwiftyPharo

@MainActor
final class PharoStyledSource {
    let widget: Frame

    private let label = Label(str: "")

    init(source: String, errorPosition: Int?) {
        label.add(cssClass: "monospace")
        label.selectable = true
        label.wrap = true
        label.wrapMode = .wordChar
        label.xalign = 0
        label.marginStart = 8
        label.marginEnd = 8
        label.marginTop = 8
        label.marginBottom = 8

        widget = Frame()
        widget.set(child: label)

        Self.show(source, styledBy: [], errorPosition: errorPosition, in: label)
        Task { @MainActor [label] in
            guard let spans = try? await PharoRuntime.shared.styleSpans(in: source, isMethod: false) else { return }
            Self.show(source, styledBy: spans, errorPosition: errorPosition, in: label)
        }
    }

    private static func show(_ source: String, styledBy spans: [PharoStyleSpan], errorPosition: Int?, in label: Label) {
        let units = Array(source.utf16)
        let isDark = ThemeWatcher.currentAppearance() == .dark
        let errorOffset = errorPosition.map { min(max($0 - 1, 0), units.count) }
        var markup = ""
        var cursor = 0

        func piece(_ range: Swift.Range<Int>, color: String?, bold: Bool) {
            guard !range.isEmpty else { return }
            if let errorOffset, range.contains(errorOffset), errorOffset > range.lowerBound {
                piece(range.lowerBound..<errorOffset, color: color, bold: bold)
                piece(errorOffset..<range.upperBound, color: color, bold: bold)
                return
            }
            if errorOffset == range.lowerBound {
                markup += "<span foreground=\"#e01b24\">●</span>"
            }
            var text = StyledTextPango.escape(String(utf16CodeUnits: Array(units[range]), count: range.count))
            if bold {
                text = "<b>\(text)</b>"
            }
            if let color {
                text = "<span foreground=\"#\(color)\">\(text)</span>"
            }
            markup += text
        }

        for span in spans.sorted(by: { $0.start < $1.start }) {
            let start = span.start - 1
            guard start >= cursor, start < span.stop, span.stop <= units.count else { continue }
            piece(cursor..<start, color: nil, bold: false)
            piece(start..<span.stop, color: isDark ? span.dark : span.light, bold: span.bold)
            cursor = span.stop
        }
        piece(cursor..<units.count, color: nil, bold: false)
        if errorOffset == units.count {
            markup += "<span foreground=\"#e01b24\">●</span>"
        }
        label.setMarkup(str: markup)
    }
}
