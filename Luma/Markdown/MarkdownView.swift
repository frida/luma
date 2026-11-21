import LumaCore
import SwiftUI

struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ text: String, as dialect: MarkdownDialect) {
        blocks = MarkdownParser.parse(text, as: dialect)
    }

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let content):
            Text(content.attributedString(baseFont: headingFont(level)))
                .textSelection(.enabled)
        case .paragraph(let content):
            Text(content.attributedString()).textSelection(.enabled)
        case .blockquote(let inner):
            BlockquoteView(blocks: inner)
        case .horizontalRule:
            Divider()
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .table(let table):
            MarkdownTableView(table: table)
        case .bulletList(let items):
            BulletListView(items: items)
        case .orderedList(let items):
            OrderedListView(items: items)
        case .taskList(let items):
            TaskListView(items: items)
        case .footnotes(let items):
            FootnotesView(items: items)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        default: return .headline
        }
    }
}

private struct BlockquoteView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.secondary).frame(width: 3)
            MarkdownView(blocks: blocks)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !language.isEmpty {
                    Text(language).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyToPasteboard(code)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            Text(CodeHighlighter.highlight(code, language: language).attributed)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                ForEach(table.headers.indices, id: \.self) { column in
                    Text(table.headers[column].attributedString(baseFont: .body.bold()))
                        .gridColumnAlignment(alignment(column))
                }
            }
            Divider()
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        Text(table.rows[row][column].attributedString())
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private struct BulletListView: View {
    let items: [[InlineSpan]]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(items[i].attributedString()).textSelection(.enabled)
                }
            }
        }
    }
}

private struct OrderedListView: View {
    let items: [OrderedListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(items[i].marker).monospacedDigit().foregroundStyle(.secondary)
                    Text(items[i].content.attributedString()).textSelection(.enabled)
                }
            }
        }
    }
}

private struct TaskListView: View {
    let items: [TaskListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: items[i].isChecked ? "checkmark.square" : "square")
                        .foregroundStyle(.secondary)
                    Text(items[i].content.attributedString())
                        .strikethrough(items[i].isChecked)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct FootnotesView: View {
    let items: [FootnoteItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(items[i].key).").font(.caption).foregroundStyle(.secondary)
                    Text(items[i].content.attributedString(baseFont: .caption))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private func copyToPasteboard(_ text: String) {
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}
