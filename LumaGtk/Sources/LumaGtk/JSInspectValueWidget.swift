import Foundation
import Gtk
import LumaCore

@MainActor
final class JSInspectValueWidget {
    let widget: Widget

    private var keepAlive: [Any] = []

    static func make(value: JSInspectValue, engine: Engine, sessionID: UUID) -> JSInspectValueWidget {
        return JSInspectValueWidget(value: value, engine: engine, sessionID: sessionID)
    }

    init(value: JSInspectValue, engine: Engine, sessionID: UUID) {
        var keepers: [Any] = []
        self.widget = Self.build(
            value: value,
            engine: engine,
            sessionID: sessionID,
            keepAlive: &keepers
        )
        self.keepAlive = keepers
    }

    private static func build(
        value: JSInspectValue,
        engine: Engine,
        sessionID: UUID,
        keepAlive: inout [Any]
    ) -> Widget {
        switch value {
        case .object(_, let props):
            return makeObjectExpander(props: props, engine: engine, sessionID: sessionID, keepAlive: &keepAlive)

        case .array(_, let elements):
            return makeArrayExpander(elements: elements, engine: engine, sessionID: sessionID, keepAlive: &keepAlive)

        case .map(_, let entries):
            return makeMapExpander(entries: entries, engine: engine, sessionID: sessionID, keepAlive: &keepAlive)

        case .set(_, let elements):
            return makeSetExpander(elements: elements, engine: engine, sessionID: sessionID, keepAlive: &keepAlive)

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
        engine: Engine,
        sessionID: UUID,
        keepAlive: inout [Any]
    ) -> Widget {
        if props.isEmpty {
            return labelWithMarkup(span("{}", color: cyan))
        }
        let header = headerMarkup(
            title: "Object{\(props.count)}",
            preview: inlinePreview(forObjectProps: props),
            color: cyan
        )

        let body = Box(orientation: .vertical, spacing: 2)
        body.marginStart = 16
        body.hexpand = true
        for prop in props {
            let row = Box(orientation: .horizontal, spacing: 4)
            row.hexpand = true
            row.append(child: labelWithMarkup(span(escape(prop.displayKey + ":"), color: green)))
            let child = build(value: prop.value, engine: engine, sessionID: sessionID, keepAlive: &keepAlive)
            child.hexpand = true
            child.halign = .start
            row.append(child: child)
            body.append(child: row)
        }
        return makeExpander(headerMarkup: header, body: body)
    }

    private static func makeArrayExpander(
        elements: [JSInspectValue],
        engine: Engine,
        sessionID: UUID,
        keepAlive: inout [Any]
    ) -> Widget {
        if elements.isEmpty {
            return labelWithMarkup(span("[]", color: cyan))
        }
        let header = headerMarkup(
            title: "Array[\(elements.count)]",
            preview: inlinePreview(forArrayElements: elements),
            color: cyan
        )

        let body = Box(orientation: .vertical, spacing: 2)
        body.marginStart = 16
        body.hexpand = true
        for (idx, element) in elements.enumerated() {
            let row = Box(orientation: .horizontal, spacing: 4)
            row.hexpand = true
            row.append(child: labelWithMarkup(span("[\(idx)]", color: dim)))
            let child = build(value: element, engine: engine, sessionID: sessionID, keepAlive: &keepAlive)
            child.hexpand = true
            child.halign = .start
            row.append(child: child)
            body.append(child: row)
        }
        return makeExpander(headerMarkup: header, body: body)
    }

    private static func makeMapExpander(
        entries: [JSInspectValue.Property],
        engine: Engine,
        sessionID: UUID,
        keepAlive: inout [Any]
    ) -> Widget {
        if entries.isEmpty {
            return labelWithMarkup(span("Map{}", color: cyan))
        }
        let header = headerMarkup(title: "Map{\(entries.count)}", preview: nil, color: cyan)

        let body = Box(orientation: .vertical, spacing: 2)
        body.marginStart = 16
        body.hexpand = true
        for entry in entries {
            let row = Box(orientation: .horizontal, spacing: 4)
            row.hexpand = true
            let keyChild = build(value: entry.key, engine: engine, sessionID: sessionID, keepAlive: &keepAlive)
            row.append(child: keyChild)
            row.append(child: labelWithMarkup(span("→", color: dim)))
            let valChild = build(value: entry.value, engine: engine, sessionID: sessionID, keepAlive: &keepAlive)
            valChild.hexpand = true
            valChild.halign = .start
            row.append(child: valChild)
            body.append(child: row)
        }
        return makeExpander(headerMarkup: header, body: body)
    }

    private static func makeSetExpander(
        elements: [JSInspectValue],
        engine: Engine,
        sessionID: UUID,
        keepAlive: inout [Any]
    ) -> Widget {
        if elements.isEmpty {
            return labelWithMarkup(span("Set{}", color: cyan))
        }
        let header = headerMarkup(title: "Set{\(elements.count)}", preview: nil, color: cyan)

        let body = Box(orientation: .vertical, spacing: 2)
        body.marginStart = 16
        body.hexpand = true
        for element in elements {
            let row = Box(orientation: .horizontal, spacing: 4)
            row.hexpand = true
            row.append(child: labelWithMarkup(span("•", color: dim)))
            let child = build(value: element, engine: engine, sessionID: sessionID, keepAlive: &keepAlive)
            child.hexpand = true
            child.halign = .start
            row.append(child: child)
            body.append(child: row)
        }
        return makeExpander(headerMarkup: header, body: body)
    }

    private static func makeExpander(headerMarkup: String, body: Widget) -> Widget {
        let expander = Expander(label: "")
        expander.add(cssClass: "luma-js-expander")
        let titleLabel = Label(str: "")
        titleLabel.setMarkup(str: headerMarkup)
        titleLabel.add(cssClass: "monospace")
        titleLabel.halign = .start
        expander.set(labelWidget: titleLabel)
        expander.set(child: body)
        expander.expanded = true
        expander.halign = .start
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
        if let address = value.nativePointerAddress {
            label.selectable = false
            let wrapper = Box(orientation: .horizontal, spacing: 0)
            wrapper.halign = .start
            wrapper.append(child: label)
            AddressActionMenu.attach(to: wrapper, engine: engine, sessionID: sessionID, address: address)
            return wrapper
        }
        label.selectable = true
        return label
    }

    private static func scalarMarkup(_ value: JSInspectValue) -> String {
        switch value {
        case .number(let n):
            let s = (n.rounded(.towardZero) == n) ? String(Int(n)) : String(n)
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
