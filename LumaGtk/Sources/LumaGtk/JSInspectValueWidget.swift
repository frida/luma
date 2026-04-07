import Foundation
import Gtk
import LumaCore

@MainActor
enum JSInspectValueWidget {
    static func make(value: JSInspectValue, engine: Engine, sessionID: UUID) -> Widget {
        return build(value: value, engine: engine, sessionID: sessionID, trailing: "")
    }

    private static func build(
        value: JSInspectValue,
        engine: Engine,
        sessionID: UUID,
        trailing: String
    ) -> Widget {
        switch value {
        case .object(_, let props):
            if props.isEmpty {
                return scalarLabel(text: "{}" + trailing, engine: engine, sessionID: sessionID, address: nil)
            }
            let box = Box(orientation: .vertical, spacing: 0)
            box.hexpand = true
            box.append(child: scalarLabel(text: "{", engine: engine, sessionID: sessionID, address: nil))
            for (idx, prop) in props.enumerated() {
                let comma = idx == props.count - 1 ? "" : ","
                let row = propertyRow(
                    keyText: "\(prop.displayKey): ",
                    value: prop.value,
                    engine: engine,
                    sessionID: sessionID,
                    trailing: comma
                )
                row.marginStart = 16
                box.append(child: row)
            }
            box.append(child: scalarLabel(text: "}" + trailing, engine: engine, sessionID: sessionID, address: nil))
            return box

        case .array(_, let items):
            if items.isEmpty {
                return scalarLabel(text: "[]" + trailing, engine: engine, sessionID: sessionID, address: nil)
            }
            let box = Box(orientation: .vertical, spacing: 0)
            box.hexpand = true
            box.append(child: scalarLabel(text: "[", engine: engine, sessionID: sessionID, address: nil))
            for (idx, item) in items.enumerated() {
                let comma = idx == items.count - 1 ? "" : ","
                let child = build(value: item, engine: engine, sessionID: sessionID, trailing: comma)
                child.marginStart = 16
                box.append(child: child)
            }
            box.append(child: scalarLabel(text: "]" + trailing, engine: engine, sessionID: sessionID, address: nil))
            return box

        case .map(_, let entries):
            if entries.isEmpty {
                return scalarLabel(text: "Map{}" + trailing, engine: engine, sessionID: sessionID, address: nil)
            }
            let box = Box(orientation: .vertical, spacing: 0)
            box.hexpand = true
            box.append(child: scalarLabel(text: "Map{", engine: engine, sessionID: sessionID, address: nil))
            for (idx, entry) in entries.enumerated() {
                let comma = idx == entries.count - 1 ? "" : ","
                let row = mapEntryRow(
                    entry: entry,
                    engine: engine,
                    sessionID: sessionID,
                    trailing: comma
                )
                row.marginStart = 16
                box.append(child: row)
            }
            box.append(child: scalarLabel(text: "}" + trailing, engine: engine, sessionID: sessionID, address: nil))
            return box

        case .set(_, let items):
            if items.isEmpty {
                return scalarLabel(text: "Set[]" + trailing, engine: engine, sessionID: sessionID, address: nil)
            }
            let box = Box(orientation: .vertical, spacing: 0)
            box.hexpand = true
            box.append(child: scalarLabel(text: "Set[", engine: engine, sessionID: sessionID, address: nil))
            for (idx, item) in items.enumerated() {
                let comma = idx == items.count - 1 ? "" : ","
                let row = bulletRow(
                    value: item,
                    engine: engine,
                    sessionID: sessionID,
                    trailing: comma
                )
                row.marginStart = 16
                box.append(child: row)
            }
            box.append(child: scalarLabel(text: "]" + trailing, engine: engine, sessionID: sessionID, address: nil))
            return box

        default:
            return scalarLabel(
                text: value.inlineDescription + trailing,
                engine: engine,
                sessionID: sessionID,
                address: value.nativePointerAddress
            )
        }
    }

    private static func propertyRow(
        keyText: String,
        value: JSInspectValue,
        engine: Engine,
        sessionID: UUID,
        trailing: String
    ) -> Widget {
        if isContainer(value) && !isEmptyContainer(value) {
            let box = Box(orientation: .vertical, spacing: 0)
            box.hexpand = true
            let header = scalarLabel(text: keyText, engine: engine, sessionID: sessionID, address: nil)
            box.append(child: header)
            let child = build(value: value, engine: engine, sessionID: sessionID, trailing: trailing)
            box.append(child: child)
            return box
        }
        let row = Box(orientation: .horizontal, spacing: 0)
        row.hexpand = true
        row.append(child: scalarLabel(text: keyText, engine: engine, sessionID: sessionID, address: nil))
        row.append(child: scalarLabel(
            text: value.inlineDescription + trailing,
            engine: engine,
            sessionID: sessionID,
            address: value.nativePointerAddress
        ))
        return row
    }

    private static func mapEntryRow(
        entry: JSInspectValue.Property,
        engine: Engine,
        sessionID: UUID,
        trailing: String
    ) -> Widget {
        let row = Box(orientation: .horizontal, spacing: 0)
        row.hexpand = true
        row.append(child: scalarLabel(
            text: entry.key.inlineDescription,
            engine: engine,
            sessionID: sessionID,
            address: entry.key.nativePointerAddress
        ))
        row.append(child: scalarLabel(text: " => ", engine: engine, sessionID: sessionID, address: nil))
        if isContainer(entry.value) && !isEmptyContainer(entry.value) {
            let column = Box(orientation: .vertical, spacing: 0)
            column.hexpand = true
            column.append(child: row)
            let child = build(value: entry.value, engine: engine, sessionID: sessionID, trailing: trailing)
            column.append(child: child)
            return column
        }
        row.append(child: scalarLabel(
            text: entry.value.inlineDescription + trailing,
            engine: engine,
            sessionID: sessionID,
            address: entry.value.nativePointerAddress
        ))
        return row
    }

    private static func bulletRow(
        value: JSInspectValue,
        engine: Engine,
        sessionID: UUID,
        trailing: String
    ) -> Widget {
        if isContainer(value) && !isEmptyContainer(value) {
            let column = Box(orientation: .vertical, spacing: 0)
            column.hexpand = true
            column.append(child: scalarLabel(text: "• ", engine: engine, sessionID: sessionID, address: nil))
            let child = build(value: value, engine: engine, sessionID: sessionID, trailing: trailing)
            column.append(child: child)
            return column
        }
        let row = Box(orientation: .horizontal, spacing: 0)
        row.hexpand = true
        row.append(child: scalarLabel(text: "• ", engine: engine, sessionID: sessionID, address: nil))
        row.append(child: scalarLabel(
            text: value.inlineDescription + trailing,
            engine: engine,
            sessionID: sessionID,
            address: value.nativePointerAddress
        ))
        return row
    }

    private static func scalarLabel(
        text: String,
        engine: Engine,
        sessionID: UUID,
        address: UInt64?
    ) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "monospace")
        label.halign = .start
        label.wrap = true
        label.selectable = true
        if let address {
            AddressActionMenu.attach(to: label, engine: engine, sessionID: sessionID, address: address)
        }
        return label
    }

    private static func isContainer(_ value: JSInspectValue) -> Bool {
        switch value {
        case .object, .array, .map, .set:
            return true
        default:
            return false
        }
    }

    private static func isEmptyContainer(_ value: JSInspectValue) -> Bool {
        switch value {
        case .object(_, let props): return props.isEmpty
        case .array(_, let items): return items.isEmpty
        case .map(_, let entries): return entries.isEmpty
        case .set(_, let items): return items.isEmpty
        default: return false
        }
    }
}
