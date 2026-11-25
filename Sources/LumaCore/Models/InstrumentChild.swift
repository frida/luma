import Foundation

public struct ChildRef: Hashable, Sendable, Codable {
    public let template: String
    public let id: String

    public init(template: String, id: String) {
        self.template = template
        self.id = id
    }

    func toWireJSON() -> [String: Any] {
        ["template": template, "id": id]
    }

    static func fromWireJSON(_ raw: Any?) -> ChildRef? {
        guard let obj = raw as? [String: Any], let template = obj["template"] as? String, let id = obj["id"] as? String else { return nil }
        return ChildRef(template: template, id: id)
    }
}

public struct InstrumentChildTemplate: Codable, Identifiable, Sendable, Equatable {
    public static let maxCount = 8
    public static let maxWidgets = 8

    public var id: String
    public var name: String
    public var symbol: String?
    public var widgets: [InstrumentWidget]
    public var layout: InstrumentLayout?

    public init(id: String, name: String, symbol: String? = nil, widgets: [InstrumentWidget], layout: InstrumentLayout? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.widgets = widgets
        self.layout = layout
    }

    public var persists: Bool {
        widgets.contains { $0.persistence == .session }
    }

    public var pageLayout: InstrumentLayout {
        layout ?? .stack(of: widgets)
    }

    func toWireJSON() -> [String: Any] {
        var out: [String: Any] = ["id": id, "name": name, "widgets": widgets.map { $0.toWireJSON() }]
        if let symbol {
            out["icon"] = ["kind": "symbolic", "value": symbol]
        }
        if let layout {
            out["layout"] = layout.wireJSON
        }
        return out
    }

    static func fromWireJSON(_ obj: [String: Any]) -> InstrumentChildTemplate? {
        guard let id = obj["id"] as? String, let name = obj["name"] as? String, let widgetObjs = obj["widgets"] as? [[String: Any]] else { return nil }
        let widgets = widgetObjs.compactMap(InstrumentWidget.fromWireJSON)
        let wireLayout = obj["layout"]
        let layout = wireLayout.flatMap { InstrumentLayout.fromWireJSON($0, placing: widgets) }
        guard widgets.count == widgetObjs.count, (wireLayout == nil) == (layout == nil) else { return nil }
        return InstrumentChildTemplate(
            id: id, name: name, symbol: (obj["icon"] as? [String: Any])?["value"] as? String, widgets: widgets, layout: layout)
    }

    static func countProblem(_ templates: [InstrumentChildTemplate], pageWidgets: Int) -> String? {
        if templates.count > maxCount {
            return "has \(templates.count) kinds of children; at most \(maxCount) are allowed"
        }
        let total = pageWidgets + templates.reduce(0) { $0 + $1.widgets.count }
        return total > InstrumentWidget.maxCount ? "declares \(total) widgets in all; at most \(InstrumentWidget.maxCount) are allowed" : nil
    }

    var problem: InstrumentWidget.Problem? {
        if id.isEmpty || id.count > InstrumentWidget.maxIDLength {
            return .init(path: [.key("id")], text: id.isEmpty ? "must not be empty" : "is longer than \(InstrumentWidget.maxIDLength) characters")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > InstrumentWidget.maxNameLength {
            return .init(path: [.key("name")], text: name.count > InstrumentWidget.maxNameLength
                ? "is longer than \(InstrumentWidget.maxNameLength) characters" : "must not be empty; a kind of child needs one")
        }
        if widgets.isEmpty {
            return .init(path: [.key("widgets")], text: "a child needs at least one widget")
        }
        if widgets.count > Self.maxWidgets {
            return .init(path: [.key("widgets")], text: "has \(widgets.count) widgets; a child holds at most \(Self.maxWidgets)")
        }
        var seen: Set<String> = []
        guard let index = widgets.firstIndex(where: { !seen.insert($0.id).inserted }) else { return nil }
        return .init(path: [.key("widgets"), .index(index), .key("id")], text: "\"\(widgets[index].id)\" is already the id of another widget")
    }
}

public struct InstrumentChild: Identifiable, Sendable, Equatable {
    public static let maxPerInstance = 256

    public let ref: ChildRef
    public var position: Int
    public var title: String
    public var subtitle: String?
    public var badge: ChildBadge?

    public var id: ChildRef {
        ref
    }

    func toWireJSON() -> [String: Any] {
        var out: [String: Any] = ["template": ref.template, "id": ref.id, "position": position, "title": title]
        if let subtitle {
            out["subtitle"] = subtitle
        }
        if let badge {
            out["badge"] = ["text": badge.text, "tone": badge.tone.rawValue]
        }
        return out
    }

    static func fromWireJSON(_ obj: [String: Any]) -> InstrumentChild? {
        guard let ref = ChildRef.fromWireJSON(obj), let position = obj["position"] as? Int, let title = obj["title"] as? String else { return nil }
        let badge = (obj["badge"] as? [String: Any]).flatMap { badge -> ChildBadge? in
            guard let text = badge["text"] as? String else { return nil }
            return ChildBadge(text: text, tone: (badge["tone"] as? String).flatMap(ChildBadge.Tone.init(rawValue:)) ?? .neutral)
        }
        return InstrumentChild(ref: ref, position: position, title: title, subtitle: obj["subtitle"] as? String, badge: badge)
    }
}

public struct ChildBadge: Codable, Sendable, Equatable {
    public enum Tone: String, Codable, Sendable, CaseIterable {
        case neutral
        case active
        case waiting
        case ended
        case failed
    }

    public var text: String
    public var tone: Tone
}

public struct ChildSelectionRequest: Sendable, Equatable {
    public let sessionID: UUID
    public let instanceID: UUID
    public let child: ChildRef?
}

extension CustomInstrumentDef {
    public var childrenProblem: InstrumentWidget.Problem? {
        Self.childrenProblem(children, pageWidgets: widgets)
    }

    static func childrenProblem(_ templates: [InstrumentChildTemplate], pageWidgets: [InstrumentWidget]) -> InstrumentWidget.Problem? {
        let base: [InstrumentWidget.Problem.Step] = [.key("luma"), .key("children")]
        if let text = InstrumentChildTemplate.countProblem(templates, pageWidgets: pageWidgets.count) {
            return .init(path: base, text: text)
        }
        var seen: Set<String> = []
        if let index = templates.firstIndex(where: { !seen.insert($0.id).inserted }) {
            return .init(path: base + [.index(index), .key("id")], text: "\"\(templates[index].id)\" is already the id of another kind of child")
        }
        for (index, template) in templates.enumerated() {
            let here = base + [.index(index)]
            if let problem = template.problem {
                return .init(path: here + problem.path, text: problem.text)
            }
            for (widgetIndex, widget) in template.widgets.enumerated() {
                if let problem = widget.problem {
                    return .init(path: here + [.key("widgets"), .index(widgetIndex)] + problem.path, text: problem.text)
                }
            }
            if let problem = template.layout?.problem(
                placing: template.widgets, keys: .camelCase,
                widgetsName: "luma.children[\(index)].widgets", layoutName: "luma.children[\(index)].layout")
            {
                return .init(path: here + [.key("layout")] + problem.path, text: problem.text)
            }
        }
        guard !templates.isEmpty, let index = pageWidgets.firstIndex(where: { $0.id == "children" }) else { return nil }
        return .init(
            path: [.key("luma"), .key("widgets"), .index(index), .key("id")],
            text: "\"children\" names the restored state of an instrument's children; choose another id")
    }

    func widget(atSlot slot: String) -> InstrumentWidget? {
        let (child, widgetID) = WidgetSlot.split(slot)
        let widgets = child.map { child in children.first { $0.id == child.template }?.widgets ?? [] } ?? self.widgets
        return widgets.first { $0.id == widgetID }
    }
}

extension InstrumentChild {
    public func widgetKey(_ widgetID: String) -> String {
        WidgetSlot.key(widget: widgetID, child: ref)
    }
}

enum WidgetSlot {
    static func key(widget: String, child: ChildRef?) -> String {
        child.map { prefix(of: $0) + widget } ?? widget
    }

    static func prefix(of ref: ChildRef) -> String {
        "\(ref.template)\u{1F}\(ref.id)\u{1F}"
    }

    static func split(_ key: String) -> (child: ChildRef?, widget: String) {
        let parts = key.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return (nil, key) }
        return (ChildRef(template: parts[0], id: parts[1]), parts[2])
    }

    static func addTarget(_ slot: String, to payload: inout [String: Any]) {
        let (child, widget) = split(slot)
        payload["widget"] = widget
        payload["child"] = child?.toWireJSON()
    }

    static func target(in payload: [String: Any]) -> String? {
        guard let widget = payload["widget"] as? String else { return nil }
        return key(widget: widget, child: ChildRef.fromWireJSON(payload["child"]))
    }
}
