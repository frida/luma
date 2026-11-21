import Foundation

public enum MarkdownParser {
    public static func parse(_ text: String, as dialect: MarkdownDialect) -> [MarkdownBlock] {
        var parser = Parser(text: text, dialect: dialect)
        return parser.run()
    }

    private struct Parser {
        let lines: [Substring]
        let dialect: MarkdownDialect
        var index = 0
        var blocks: [MarkdownBlock] = []
        var textBuffer: [Substring] = []

        init(text: String, dialect: MarkdownDialect) {
            lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            self.dialect = dialect
        }

        mutating func run() -> [MarkdownBlock] {
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if consumeParagraphBreak(trimmed) { continue }
                if consumeCodeFence(trimmed) { continue }
                if consumeBlockquote(line) { continue }
                if consumeHeading(trimmed) { continue }
                if consumeHorizontalRule(trimmed) { continue }
                if consumeTaskList(trimmed) { continue }
                if consumeOrderedList(trimmed) { continue }
                if consumeBulletList(trimmed) { continue }
                if consumeFootnotes(trimmed) { continue }
                if consumeTable() { continue }
                textBuffer.append(line)
                index += 1
            }
            flushText()
            return blocks
        }

        mutating func consumeParagraphBreak(_ trimmed: String) -> Bool {
            guard dialect == .document, trimmed.isEmpty else { return false }
            flushText()
            index += 1
            return true
        }

        mutating func flushText() {
            let text = paragraphText(textBuffer)
            textBuffer.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(.paragraph(InlineMarkdownParser.parse(text)))
        }

        func paragraphText(_ paragraphLines: some Sequence<Substring>) -> String {
            switch dialect {
            case .conversation:
                return paragraphLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            case .document:
                return paragraphLines.map(reflowedLine).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        func reflowedLine(_ line: Substring) -> String {
            let content = line.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("  ") {
                return content + "\n"
            }
            if content.hasSuffix("\\") {
                return String(content.dropLast()) + "\n"
            }
            return content + " "
        }

        mutating func consumeCodeFence(_ trimmed: String) -> Bool {
            guard isCodeFence(trimmed) else { return false }
            flushText()
            let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var body: [Substring] = []
            index += 1
            while index < lines.count {
                let line = lines[index]
                if isCodeFence(line.trimmingCharacters(in: .whitespaces)) {
                    index += 1
                    break
                }
                body.append(line)
                index += 1
            }
            blocks.append(.code(language: language, code: body.joined(separator: "\n")))
            return true
        }

        func isCodeFence(_ trimmed: String) -> Bool {
            trimmed.hasPrefix("```")
        }

        mutating func consumeBlockquote(_ line: Substring) -> Bool {
            guard quotedContent(line) != nil else { return false }
            flushText()
            var inner: [String] = []
            while index < lines.count, let content = quotedContent(lines[index]) {
                inner.append(content)
                index += 1
            }
            blocks.append(.blockquote(MarkdownParser.parse(inner.joined(separator: "\n"), as: dialect)))
            return true
        }

        func quotedContent(_ line: Substring) -> String? {
            let trimmed = line.drop(while: { $0 == " " })
            guard trimmed.first == ">" else { return nil }
            let rest = trimmed.dropFirst()
            return rest.first == " " ? String(rest.dropFirst()) : String(rest)
        }

        mutating func consumeHeading(_ trimmed: String) -> Bool {
            guard let heading = heading(trimmed) else { return false }
            flushText()
            blocks.append(heading)
            index += 1
            return true
        }

        func heading(_ trimmed: String) -> MarkdownBlock? {
            guard trimmed.hasPrefix("#") else { return nil }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(level), trimmed.count > level else { return nil }
            let separator = trimmed.index(trimmed.startIndex, offsetBy: level)
            guard trimmed[separator] == " " else { return nil }
            let content = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }
            return .heading(level: level, content: InlineMarkdownParser.parse(content))
        }

        mutating func consumeHorizontalRule(_ trimmed: String) -> Bool {
            guard isHorizontalRule(trimmed) else { return false }
            flushText()
            blocks.append(.horizontalRule)
            index += 1
            return true
        }

        func isHorizontalRule(_ trimmed: String) -> Bool {
            let markers: Set<Character> = ["-", "_", "*"]
            guard let first = trimmed.first, markers.contains(first), trimmed.count >= 3 else { return false }
            return trimmed.allSatisfy({ $0 == first })
        }

        mutating func consumeTaskList(_ trimmed: String) -> Bool {
            guard taskItem(trimmed) != nil else { return false }
            flushText()
            blocks.append(.taskList(consumeItems(parsedBy: taskItem)))
            return true
        }

        func taskItem(_ trimmed: String) -> TaskListItem? {
            let bullets: Set<Character> = ["-", "*", "+"]
            guard let first = trimmed.first, bullets.contains(first), trimmed.count >= 5 else { return nil }
            let afterBullet = trimmed.dropFirst()
            guard afterBullet.hasPrefix(" [") else { return nil }
            let markIndex = afterBullet.index(afterBullet.startIndex, offsetBy: 2)
            let mark = afterBullet[markIndex]
            let afterMark = afterBullet.index(after: markIndex)
            guard afterBullet[afterMark...].hasPrefix("] ") else { return nil }
            let checked = mark == "x" || mark == "X"
            guard checked || mark == " " else { return nil }
            let content = afterBullet[afterBullet.index(afterMark, offsetBy: 2)...]
            return TaskListItem(isChecked: checked, content: InlineMarkdownParser.parse(String(content)))
        }

        mutating func consumeOrderedList(_ trimmed: String) -> Bool {
            guard let first = orderedItem(trimmed), canOpenOrderedList(startingWith: first) else { return false }
            flushText()
            blocks.append(.orderedList(consumeItems(parsedBy: orderedItem)))
            return true
        }

        func orderedItem(_ trimmed: String) -> OrderedListItem? {
            let digits = trimmed.prefix(while: \.isNumber)
            guard !digits.isEmpty, let number = Int(digits) else { return nil }
            let afterDigits = trimmed[digits.endIndex...]
            guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
            let rest = afterDigits.dropFirst()
            guard rest.first == " " else { return nil }
            let content = rest.dropFirst()
            return OrderedListItem(
                number: number,
                delimiter: String(delimiter),
                content: InlineMarkdownParser.parse(String(content))
            )
        }

        func canOpenOrderedList(startingWith first: OrderedListItem) -> Bool {
            switch dialect {
            case .conversation:
                return true
            case .document:
                return textBuffer.isEmpty || first.number == 1
            }
        }

        mutating func consumeBulletList(_ trimmed: String) -> Bool {
            guard bulletItem(trimmed) != nil else { return false }
            flushText()
            blocks.append(.bulletList(consumeItems(parsedBy: bulletItem)))
            return true
        }

        func bulletItem(_ trimmed: String) -> [InlineSpan]? {
            let bullets: Set<Character> = ["-", "*", "+"]
            guard let first = trimmed.first, bullets.contains(first), trimmed.dropFirst().first == " " else {
                return nil
            }
            return InlineMarkdownParser.parse(String(trimmed.dropFirst(2)))
        }

        mutating func consumeFootnotes(_ trimmed: String) -> Bool {
            guard footnote(trimmed) != nil else { return false }
            flushText()
            blocks.append(.footnotes(consumeItems(parsedBy: footnote)))
            return true
        }

        func footnote(_ trimmed: String) -> FootnoteItem? {
            guard trimmed.hasPrefix("[^"), let close = trimmed.range(of: "]:") else { return nil }
            let key = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound]
            guard !key.isEmpty else { return nil }
            let content = trimmed[close.upperBound...].trimmingCharacters(in: .whitespaces)
            return FootnoteItem(key: String(key), content: InlineMarkdownParser.parse(content))
        }

        mutating func consumeTable() -> Bool {
            guard let head = tableHead(at: index) else { return false }
            flushText()
            index += 2
            var rows: [[[InlineSpan]]] = []
            while index < lines.count {
                let rowTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard rowTrimmed.contains("|"), tableAlignments(rowTrimmed) == nil else { break }
                var cells = splitRow(rowTrimmed)
                while cells.count < head.headers.count { cells.append([]) }
                rows.append(Array(cells.prefix(head.headers.count)))
                index += 1
            }
            blocks.append(
                .table(MarkdownTable(headers: head.headers, rows: rows, alignments: head.alignments))
            )
            return true
        }

        func tableHead(at position: Int) -> (headers: [[InlineSpan]], alignments: [ColumnAlignment])? {
            let trimmed = lines[position].trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("|"), position + 1 < lines.count,
                let alignments = tableAlignments(lines[position + 1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            let headers = splitRow(trimmed)
            guard headers.count == alignments.count, !headers.isEmpty else { return nil }
            return (headers, alignments)
        }

        func tableAlignments(_ trimmed: String) -> [ColumnAlignment]? {
            guard trimmed.contains("|"), trimmed.contains("-") else { return nil }
            let cells = splitRawRow(trimmed)
            guard !cells.isEmpty else { return nil }
            var alignments: [ColumnAlignment] = []
            for cell in cells {
                let spec = cell.trimmingCharacters(in: .whitespaces)
                guard spec.allSatisfy({ $0 == "-" || $0 == ":" }), spec.contains("-") else { return nil }
                let left = spec.hasPrefix(":")
                let right = spec.hasSuffix(":")
                alignments.append(left && right ? .center : right ? .trailing : .leading)
            }
            return alignments
        }

        func splitRow(_ trimmed: String) -> [[InlineSpan]] {
            splitRawRow(trimmed).map { InlineMarkdownParser.parse($0.trimmingCharacters(in: .whitespaces)) }
        }

        func splitRawRow(_ trimmed: String) -> [String] {
            var cells: [String] = []
            var current = ""
            var escaped = false
            var body = Substring(trimmed)
            if body.hasPrefix("|") { body = body.dropFirst() }
            if body.hasSuffix("|") { body = body.dropLast() }
            for ch in body {
                if escaped {
                    current.append(ch)
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "|" {
                    cells.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            cells.append(current)
            return cells
        }

        mutating func consumeItems<Item>(parsedBy item: (String) -> Item?) -> [Item] {
            var items: [Item] = []
            while index < lines.count {
                let itemLines = lines[index..<itemEnd(from: index)]
                guard let parsed = item(paragraphText(itemLines).trimmingCharacters(in: .whitespaces)) else { break }
                items.append(parsed)
                index = nextItemStart(after: itemLines.endIndex, parsedBy: item)
            }
            return items
        }

        func itemEnd(from start: Int) -> Int {
            switch dialect {
            case .conversation:
                return start + 1
            case .document:
                return (start + 1..<lines.count).first(where: endsItem) ?? lines.count
            }
        }

        func endsItem(at position: Int) -> Bool {
            let line = lines[position]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || isCodeFence(trimmed) || quotedContent(line) != nil || heading(trimmed) != nil
                || isHorizontalRule(trimmed) || taskItem(trimmed) != nil || orderedItem(trimmed) != nil
                || bulletItem(trimmed) != nil || footnote(trimmed) != nil || tableHead(at: position) != nil
        }

        func nextItemStart<Item>(after end: Int, parsedBy item: (String) -> Item?) -> Int {
            guard dialect == .document,
                let next = (end..<lines.count).first(where: { !lines[$0].allSatisfy(\.isWhitespace) }),
                item(lines[next].trimmingCharacters(in: .whitespaces)) != nil
            else { return end }
            return next
        }
    }
}
