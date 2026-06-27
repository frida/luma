import Foundation
import Gtk
import LumaCore

@MainActor
private final class ChunkedRowsPager {
    private let body: Box
    private let count: Int
    private let noun: String
    private var shown: Int
    private let makeRow: (Int, inout [Any]) -> Widget
    private let onExpand: () -> Void
    private var deferredKeepers: [Any] = []
    private var currentButton: Button?
    private var lastRow: Widget

    init(
        body: Box,
        count: Int,
        noun: String,
        shown: Int,
        lastRow: Widget,
        onExpand: @escaping () -> Void,
        makeRow: @escaping (Int, inout [Any]) -> Widget
    ) {
        self.body = body
        self.count = count
        self.noun = noun
        self.shown = shown
        self.lastRow = lastRow
        self.onExpand = onExpand
        self.makeRow = makeRow
    }

    func installButton() {
        let button = Button(label: "")
        button.halign = .start
        button.add(cssClass: "luma-js-show-more")
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advance()
            }
        }
        body.append(child: button)
        currentButton = button
        updateButtonLabel()
    }

    private func advance() {
        guard let button = currentButton else { return }
        let chunkEnd = min(shown + JSInspectValueWidget.chunkSize, count)
        for idx in shown..<chunkEnd {
            let row = makeRow(idx, &deferredKeepers)
            body.insertChildAfter(child: row, sibling: lastRow)
            lastRow = row
        }
        shown = chunkEnd
        if shown < count {
            updateButtonLabel()
        } else {
            button.visible = false
        }
        onExpand()
    }

    private func updateButtonLabel() {
        guard let button = currentButton else { return }
        let remaining = count - shown
        let next = min(JSInspectValueWidget.chunkSize, remaining)
        button.label = "Show \(next) more (\(remaining) \(noun) left)…"
    }
}

@MainActor
final class JSInspectValueWidget {
    let widget: Widget

    private var keepAlive: [Any] = []

    static func make(value: JSInspectValue, engine: Engine, sessionID: UUID, onExpand: @escaping () -> Void = {}) -> JSInspectValueWidget {
        return JSInspectValueWidget(value: value, engine: engine, sessionID: sessionID, onExpand: onExpand)
    }

    init(value: JSInspectValue, engine: Engine, sessionID: UUID, onExpand: @escaping () -> Void) {
        var keepers: [Any] = []
        self.widget = Self.build(
            value: value,
            depth: 0,
            engine: engine,
            sessionID: sessionID,
            onExpand: onExpand,
            keepAlive: &keepers
        )
        self.keepAlive = keepers
    }

    fileprivate static let chunkSize = 5

    private static func build(
        value: JSInspectValue,
        depth: Int,
        engine: Engine,
        sessionID: UUID,
        onExpand: @escaping () -> Void,
        keepAlive: inout [Any]
    ) -> Widget {
        switch value {
        case .object(_, let props):
            return makeObjectExpander(props: props, depth: depth, engine: engine, sessionID: sessionID, onExpand: onExpand, keepAlive: &keepAlive)

        case .array(_, let elements):
            return makeArrayExpander(elements: elements, depth: depth, engine: engine, sessionID: sessionID, onExpand: onExpand, keepAlive: &keepAlive)

        case .map(_, let entries):
            return makeMapExpander(entries: entries, depth: depth, engine: engine, sessionID: sessionID, onExpand: onExpand, keepAlive: &keepAlive)

        case .set(_, let elements):
            return makeSetExpander(elements: elements, depth: depth, engine: engine, sessionID: sessionID, onExpand: onExpand, keepAlive: &keepAlive)

        case .bytes(let bytes):
            return makeBytesView(bytes: bytes, keepAlive: &keepAlive)

        case .error(let name, let message, let stack):
            return makeErrorView(name: name, message: message, stack: stack)

        default:
            return makeScalarLabel(value: value, engine: engine, sessionID: sessionID)
        }
    }

    private static func makeObjectExpander(
        props: [JSInspectValue.Property],
        depth: Int,
        engine: Engine,
        sessionID: UUID,
        onExpand: @escaping () -> Void,
        keepAlive: inout [Any]
    ) -> Widget {
        if props.isEmpty {
            return labelWithMarkup(span("{}", color: cyan))
        }
        let body = makeBodyBox()
        appendChunkedRows(into: body, count: props.count, noun: "properties", onExpand: onExpand, keepAlive: &keepAlive) { idx, keepers in
            let prop = props[idx]
            let row = Box(orientation: .horizontal, spacing: 4)
            row.hexpand = true
            let key = labelWithMarkup(span(escape(prop.displayKey + ":"), color: green))
            key.valign = .start
            if isComposite(prop.value) { key.marginTop = 2 }
            row.append(child: key)
            let child = build(value: prop.value, depth: depth + 1, engine: engine, sessionID: sessionID, onExpand: onExpand, keepAlive: &keepers)
            child.hexpand = true
            child.halign = .start
            row.append(child: child)
            return row
        }
        return makeExpander(
            title: "Object{\(props.count)}",
            preview: inlinePreview(forObjectProps: props),
            color: cyan,
            depth: depth,
            body: body
        )
    }

    private static func makeArrayExpander(
        elements: [JSInspectValue],
        depth: Int,
        engine: Engine,
        sessionID: UUID,
        onExpand: @escaping () -> Void,
        keepAlive: inout [Any]
    ) -> Widget {
        if elements.isEmpty {
            return labelWithMarkup(span("[]", color: cyan))
        }
        let body = makeBodyBox()
        appendChunkedRows(into: body, count: elements.count, noun: "items", onExpand: onExpand, keepAlive: &keepAlive) { idx, keepers in
            let row = Box(orientation: .horizontal, spacing: 4)
            row.hexpand = true
            let indexLabel = labelWithMarkup(span("[\(idx)]", color: dim))
            indexLabel.valign = .start
            if isComposite(elements[idx]) { indexLabel.marginTop = 2 }
            row.append(child: indexLabel)
            let child = build(value: elements[idx], depth: depth + 1, engine: engine, sessionID: sessionID, onExpand: onExpand, keepAlive: &keepers)
            child.hexpand = true
            child.halign = .start
            row.append(child: child)
            return row
        }
        return makeExpander(
            title: "Array[\(elements.count)]",
            preview: inlinePreview(forArrayElements: elements),
            color: cyan,
            depth: depth,
            body: body
        )
    }

    private static func makeMapExpander(
        entries: [JSInspectValue.Property],
        depth: Int,
        engine: Engine,
        sessionID: UUID,
        onExpand: @escaping () -> Void,
        keepAlive: inout [Any]
    ) -> Widget {
        if entries.isEmpty {
            return labelWithMarkup(span("Map{}", color: cyan))
        }
        let body = makeBodyBox()
        appendChunkedRows(into: body, count: entries.count, noun: "entries", onExpand: onExpand, keepAlive: &keepAlive) { idx, keepers in
            let entry = entries[idx]
            let row = Box(orientation: .horizontal, spacing: 4)
            row.hexpand = true
            let keyChild = build(value: entry.key, depth: depth + 1, engine: engine, sessionID: sessionID, onExpand: onExpand, keepAlive: &keepers)
            keyChild.valign = .start
            row.append(child: keyChild)
            let arrow = labelWithMarkup(span("→", color: dim))
            arrow.valign = .start
            if isComposite(entry.value) { arrow.marginTop = 2 }
            row.append(child: arrow)
            let valChild = build(value: entry.value, depth: depth + 1, engine: engine, sessionID: sessionID, onExpand: onExpand, keepAlive: &keepers)
            valChild.hexpand = true
            valChild.halign = .start
            row.append(child: valChild)
            return row
        }
        return makeExpander(title: "Map{\(entries.count)}", preview: nil, color: cyan, depth: depth, body: body)
    }

    private static func makeSetExpander(
        elements: [JSInspectValue],
        depth: Int,
        engine: Engine,
        sessionID: UUID,
        onExpand: @escaping () -> Void,
        keepAlive: inout [Any]
    ) -> Widget {
        if elements.isEmpty {
            return labelWithMarkup(span("Set{}", color: cyan))
        }
        let body = makeBodyBox()
        appendChunkedRows(into: body, count: elements.count, noun: "items", onExpand: onExpand, keepAlive: &keepAlive) { idx, keepers in
            let row = Box(orientation: .horizontal, spacing: 4)
            row.hexpand = true
            let bullet = labelWithMarkup(span("•", color: dim))
            bullet.valign = .start
            if isComposite(elements[idx]) { bullet.marginTop = 2 }
            row.append(child: bullet)
            let child = build(value: elements[idx], depth: depth + 1, engine: engine, sessionID: sessionID, onExpand: onExpand, keepAlive: &keepers)
            child.hexpand = true
            child.halign = .start
            row.append(child: child)
            return row
        }
        return makeExpander(title: "Set{\(elements.count)}", preview: nil, color: cyan, depth: depth, body: body)
    }

    private static func isComposite(_ value: JSInspectValue) -> Bool {
        switch value {
        case .object, .array, .map, .set: return true
        default: return false
        }
    }

    private static func makeBodyBox() -> Box {
        let body = Box(orientation: .vertical, spacing: 2)
        body.marginStart = 16
        body.hexpand = true
        return body
    }

    private static func appendChunkedRows(
        into body: Box,
        count: Int,
        noun: String,
        onExpand: @escaping () -> Void,
        keepAlive: inout [Any],
        makeRow: @escaping (Int, inout [Any]) -> Widget
    ) {
        let initial = min(count, chunkSize)
        var lastRow: Widget?
        for idx in 0..<initial {
            let row = makeRow(idx, &keepAlive)
            body.append(child: row)
            lastRow = row
        }
        guard count > initial, let lastRow else { return }
        let pager = ChunkedRowsPager(
            body: body,
            count: count,
            noun: noun,
            shown: initial,
            lastRow: lastRow,
            onExpand: onExpand,
            makeRow: makeRow
        )
        keepAlive.append(pager)
        pager.installButton()
    }

    private static func makeExpander(title: String, preview: String?, color: String, depth: Int, body: Widget) -> Widget {
        let expander = Expander(label: "")
        expander.add(cssClass: "luma-js-expander")
        let initiallyExpanded = (depth == 0)
        expander.expanded = initiallyExpanded
        expander.halign = .start
        if depth > 0 {
            expander.marginStart = -6
        }
        let titleLabel = Label(str: "")
        titleLabel.setMarkup(str: headerMarkup(title: title, preview: initiallyExpanded ? nil : preview, color: color))
        titleLabel.add(cssClass: "monospace")
        titleLabel.halign = .start
        expander.set(labelWidget: titleLabel)
        expander.set(child: body)
        expander.onNotifyExpanded { [titleLabel] expander, _ in
            MainActor.assumeIsolated {
                let visiblePreview = expander.expanded ? nil : preview
                titleLabel.setMarkup(str: headerMarkup(title: title, preview: visiblePreview, color: color))
            }
        }
        return expander
    }

    private static func makeBytesView(bytes: JSInspectValue.Bytes, keepAlive: inout [Any]) -> Widget {
        let column = Box(orientation: .vertical, spacing: 4)
        column.hexpand = true
        column.halign = .start

        let header = labelWithMarkup(
            span("Bytes(", color: mint)
                + span(escape(bytes.kind.rawValue), color: cyan)
                + span("[\(bytes.data.count)])", color: mint)
        )
        column.append(child: header)

        let hex = HexView(bytes: bytes.data)
        keepAlive.append(hex)
        hex.widget.hexpand = true
        let rows = max(1, (bytes.data.count + 15) / 16)
        hex.widget.setSizeRequest(width: -1, height: min(220, rows * 18 + 20))
        column.append(child: hex.widget)
        return column
    }

    private static func makeErrorView(name: String, message: String, stack: String) -> Widget {
        let header = message.isEmpty ? name : "\(name): \(message)"
        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.append(child: labelWithMarkup(span(escape(header), color: red)))
        if !stack.isEmpty {
            for line in stack.split(separator: "\n", omittingEmptySubsequences: false) {
                column.append(child: labelWithMarkup(span(escape("  " + String(line)), color: dim)))
            }
        }
        return column
    }

    private static func makeScalarLabel(
        value: JSInspectValue,
        engine: Engine,
        sessionID: UUID
    ) -> Widget {
        let label = Label(str: "")
        label.setMarkup(str: scalarMarkup(value))
        label.add(cssClass: "monospace")
        label.halign = .start
        label.wrap = true
        if case .nativePointer(let pointerText) = value, let address = value.nativePointerAddress {
            label.selectable = false
            let wrapper = Box(orientation: .horizontal, spacing: 0)
            wrapper.halign = .start
            wrapper.append(child: label)
            AddressActionMenu.attach(to: wrapper, engine: engine, sessionID: sessionID, address: address, value: pointerText)
            return wrapper
        }
        label.selectable = true
        return label
    }

    private static func scalarMarkup(_ value: JSInspectValue) -> String {
        switch value {
        case .number(let n):
            let s: String
            if n.rounded(.towardZero) == n {
                s = Int(exactly: n).map(String.init) ?? String(format: "%.0f", n)
            } else {
                s = String(n)
            }
            return span(escape(s), color: cyan)
        case .string(let s):
            return span(escape("\"\(s)\""), color: mint)
        case .nativePointer(let s):
            return span(escape(s), color: orange)
        case .null:
            return span("null", color: orange)
        case .undefined:
            return span("undefined", color: orange)
        case .boolean(let b):
            return span(b ? "true" : "false", color: orange)
        case .function(let sig):
            return span(escape(sig), color: purple)
        case .bigInt(let s):
            return span(escape(s + "n"), color: cyan)
        case .symbol(let t):
            return span(escape(t), color: purple)
        case .date(let s):
            return span("Date(", color: blue) + span(escape(s), color: mint) + span(")", color: blue)
        case .regExp(let pattern, let flags):
            return span("/", color: purple) + span(escape(pattern), color: mint)
                + span("/", color: purple) + span(escape(flags), color: purple)
        case .promise:
            return span("Promise", color: purple)
        case .weakMap:
            return span("WeakMap", color: purple)
        case .weakSet:
            return span("WeakSet", color: purple)
        case .depthLimit(let kind):
            let label: String
            switch kind {
            case .object: label = "Object<depth limit reached>"
            case .array: label = "Array<depth limit reached>"
            case .map: label = "Map<depth limit reached>"
            case .set: label = "Set<depth limit reached>"
            }
            return span(escape(label), color: orange)
        case .circular(let id):
            return span(escape("⟳ circular *\(id)"), color: orange)
        default:
            return escape(value.inlineDescription)
        }
    }

    // MARK: - Markup helpers

    private static let cyan = "#00b4d8"
    private static let mint = "#00c7be"
    private static let green = "#34c759"
    private static let orange = "#ff9500"
    private static let purple = "#af52de"
    private static let red = "#ff3b30"
    private static let blue = "#007aff"
    private static let dim = "#8e8e93"

    private static func span(_ text: String, color: String) -> String {
        return "<span foreground=\"\(color)\">\(text)</span>"
    }

    private static func escape(_ s: String) -> String {
        StyledTextPango.escape(s)
    }

    private static func headerMarkup(title: String, preview: String?, color: String) -> String {
        var out = span(escape(title), color: color)
        if let preview {
            out += " " + span(escape(preview), color: dim)
        }
        return out
    }

    private static func labelWithMarkup(_ markup: String) -> Label {
        let label = Label(str: "")
        label.setMarkup(str: markup)
        label.add(cssClass: "monospace")
        label.halign = .start
        label.selectable = true
        return label
    }

    private static func inlinePreview(forObjectProps props: [JSInspectValue.Property]) -> String? {
        if props.isEmpty { return nil }
        let parts = props.prefix(3).map { "\($0.displayKey): \($0.value.inlineDescription)" }
        return "{" + parts.joined(separator: ", ") + (props.count > 3 ? ", …}" : "}")
    }

    private static func inlinePreview(forArrayElements elements: [JSInspectValue]) -> String? {
        if elements.isEmpty { return nil }
        let parts = elements.prefix(3).map { $0.inlineDescription }
        return "[" + parts.joined(separator: ", ") + (elements.count > 3 ? ", …]" : "]")
    }
}
