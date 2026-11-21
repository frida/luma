import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
enum MarkdownWidget {
    static func make(markdown: String, as dialect: MarkdownDialect, dimmed: Bool = false) -> Widget {
        let box = make(blocks: MarkdownParser.parse(markdown, as: dialect))
        if dimmed {
            box.add(cssClass: "dim-label")
        }
        return box
    }

    static func make(blocks: [MarkdownBlock]) -> Box {
        let box = Box(orientation: .vertical, spacing: 8)
        box.halign = .fill
        for block in blocks {
            box.append(child: widget(for: block))
        }
        return box
    }

    private static func widget(for block: MarkdownBlock) -> Widget {
        switch block {
        case .heading(let level, let content):
            return headingLabel(level: level, content: content)
        case .paragraph(let content):
            return wrappedLabel(markup: InlineSpanPango.markup(for: content))
        case .blockquote(let inner):
            return blockquote(inner)
        case .horizontalRule:
            return Separator(orientation: .horizontal)
        case .code(let language, let code):
            return codeBlock(language: language, code: code)
        case .table(let table):
            return tableGrid(table)
        case .bulletList(let items):
            return bulletList(items)
        case .orderedList(let items):
            return orderedList(items)
        case .taskList(let items):
            return taskList(items)
        case .footnotes(let items):
            return footnotes(items)
        }
    }

    private static func headingLabel(level: Int, content: [InlineSpan]) -> Widget {
        let size = headingSize(level)
        let markup = "<span size=\"\(size)\" weight=\"bold\">\(InlineSpanPango.markup(for: content))</span>"
        return wrappedLabel(markup: markup)
    }

    private static func headingSize(_ level: Int) -> String {
        switch level {
        case 1: return "xx-large"
        case 2: return "x-large"
        case 3: return "large"
        default: return "medium"
        }
    }

    private static func blockquote(_ inner: [MarkdownBlock]) -> Widget {
        let row = Box(orientation: .horizontal, spacing: 8)
        let bar = Separator(orientation: .vertical)
        row.append(child: bar)
        let body = make(blocks: inner)
        body.add(cssClass: "dim-label")
        body.hexpand = true
        row.append(child: body)
        return row
    }

    private static func codeBlock(language: String, code: String) -> Widget {
        let box = Box(orientation: .vertical, spacing: 4)
        box.add(cssClass: "card")
        box.marginTop = 2
        box.marginBottom = 2

        let header = Box(orientation: .horizontal, spacing: 6)
        header.marginStart = 8
        header.marginEnd = 8
        header.marginTop = 6
        if !language.isEmpty {
            let tag = Label(str: language)
            tag.halign = .start
            tag.add(cssClass: "caption")
            tag.add(cssClass: "dim-label")
            header.append(child: tag)
        }
        let spacer = Label(str: "")
        spacer.hexpand = true
        header.append(child: spacer)
        let copyButton = Button(iconName: "edit-copy-symbolic")
        copyButton.add(cssClass: "flat")
        copyButton.onClicked { _ in MainActor.assumeIsolated { copyToClipboard(code) } }
        header.append(child: copyButton)
        box.append(child: header)

        let label = wrappedLabel(markup: StyledTextPango.markup(for: CodeHighlighter.highlight(code, language: language)))
        label.add(cssClass: "monospace")
        label.marginStart = 8
        label.marginEnd = 8
        label.marginBottom = 8
        box.append(child: label)
        return box
    }

    private static func tableGrid(_ table: MarkdownTable) -> Widget {
        let grid = Grid()
        grid.columnSpacing = 12
        grid.rowSpacing = 4
        for (column, header) in table.headers.enumerated() {
            let cell = cellLabel(header, alignment: table.alignments[column])
            cell.add(cssClass: "heading")
            grid.attach(child: cell, column: column, row: 0, width: 1, height: 1)
        }
        for (rowIndex, row) in table.rows.enumerated() {
            for (column, content) in row.enumerated() {
                let cell = cellLabel(content, alignment: table.alignments[column])
                grid.attach(child: cell, column: column, row: rowIndex + 1, width: 1, height: 1)
            }
        }
        return grid
    }

    private static func cellLabel(_ content: [InlineSpan], alignment: ColumnAlignment) -> Label {
        let label = Label(str: "")
        label.useMarkup = true
        label.selectable = true
        label.setMarkup(str: InlineSpanPango.markup(for: content))
        switch alignment {
        case .leading: label.halign = .start
        case .center: label.halign = .center
        case .trailing: label.halign = .end
        }
        return label
    }

    private static func bulletList(_ items: [[InlineSpan]]) -> Widget {
        listBox(items.map { ("•", InlineSpanPango.markup(for: $0)) })
    }

    private static func orderedList(_ items: [OrderedListItem]) -> Widget {
        listBox(items.map { ($0.marker, InlineSpanPango.markup(for: $0.content)) })
    }

    private static func taskList(_ items: [TaskListItem]) -> Widget {
        listBox(items.map { item in
            let marker = item.isChecked ? "☑" : "☐"
            let body = item.isChecked ? "<s>\(InlineSpanPango.markup(for: item.content))</s>" : InlineSpanPango.markup(for: item.content)
            return (marker, body)
        })
    }

    private static func footnotes(_ items: [FootnoteItem]) -> Widget {
        let box = listBox(items.map { ("\($0.key).", InlineSpanPango.markup(for: $0.content)) })
        box.add(cssClass: "dim-label")
        return box
    }

    private static func listBox(_ rows: [(marker: String, markup: String)]) -> Box {
        let box = Box(orientation: .vertical, spacing: 2)
        for row in rows {
            let line = Box(orientation: .horizontal, spacing: 6)
            line.valign = .start
            let marker = Label(str: row.marker)
            marker.valign = .start
            line.append(child: marker)
            let body = wrappedLabel(markup: row.markup)
            body.hexpand = true
            line.append(child: body)
            box.append(child: line)
        }
        return box
    }

    private static func wrappedLabel(markup: String) -> Label {
        let label = Label(str: "")
        label.halign = .fill
        label.xalign = 0
        label.wrap = true
        label.useMarkup = true
        label.selectable = true
        label.wrapMode = .wordChar
        label.maxWidthChars = 0
        label.setMarkup(str: markup)
        return label
    }

    private static func copyToClipboard(_ value: String) {
        guard let display = Display.getDefault() else { return }
        display.clipboard.set(text: value)
    }
}
