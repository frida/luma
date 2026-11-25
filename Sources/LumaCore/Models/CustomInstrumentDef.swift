import Foundation
import GRDB

public struct CustomInstrumentDef: Codable, Identifiable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "custom_instrument_def"

    public var id: UUID
    public var name: String
    public var icon: InstrumentIcon
    public var compatibility: InstrumentCompatibility
    public var minAppVersion: StoreVersion?
    public var entrypoint: String
    public var dependencies: [String: String]
    public var settings: [Setting]
    public var widgets: [InstrumentWidget]
    public var layout: InstrumentLayout?
    public var children: [InstrumentChildTemplate]
    public var createdAt: Date
    public var updatedAt: Date

    public struct Setting: Codable, Identifiable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var schema: SettingSchema
        public var optional: Bool
        public var enabledByDefault: Bool

        public init(
            id: String,
            name: String,
            schema: SettingSchema = .boolean(default: false),
            optional: Bool = false,
            enabledByDefault: Bool = true
        ) {
            self.id = id
            self.name = name
            self.schema = schema
            self.optional = optional
            self.enabledByDefault = enabledByDefault
        }

        public init(from decoder: Decoder) throws {
            try decoder.refuseUnknownKeys(CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                schema: try c.decodeIfPresent(SettingSchema.self, forKey: .schema) ?? .boolean(default: false),
                optional: try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false,
                enabledByDefault: try c.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? true)
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        icon: InstrumentIcon = .symbolic(InstrumentIconCatalog.default.id),
        compatibility: InstrumentCompatibility = .universal,
        minAppVersion: StoreVersion? = nil,
        entrypoint: String,
        dependencies: [String: String] = [:],
        settings: [Setting] = [],
        widgets: [InstrumentWidget] = [],
        layout: InstrumentLayout? = nil,
        children: [InstrumentChildTemplate] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.compatibility = compatibility
        self.minAppVersion = minAppVersion
        self.entrypoint = entrypoint
        self.dependencies = dependencies
        self.settings = settings
        self.widgets = widgets
        self.layout = layout
        self.children = children
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        icon = InstrumentIcon.decodedJSONString(row["icon"])
        let compatibilityJSON: String = row["compatibility_json"]
        compatibility = try JSONDecoder().decode(InstrumentCompatibility.self, from: Data(compatibilityJSON.utf8))
        minAppVersion = (row["min_app_version"] as String?).flatMap(StoreVersion.init)
        entrypoint = row["entrypoint"]
        let dependenciesJSON: String = row["dependencies_json"]
        dependencies = try JSONDecoder().decode([String: String].self, from: Data(dependenciesJSON.utf8))
        let settingsJSON: String = row["settings_json"]
        settings = try JSONDecoder().decode([Setting].self, from: Data(settingsJSON.utf8))
        let widgetsJSON: String = row["widgets_json"]
        widgets = try JSONDecoder().decode([InstrumentWidget].self, from: Data(widgetsJSON.utf8))
        let layoutJSON: String? = row["layout_json"]
        layout = try layoutJSON.map { try JSONDecoder().decode(InstrumentLayout.self, from: Data($0.utf8)) }
        let childrenJSON: String = row["children_json"]
        children = try JSONDecoder().decode([InstrumentChildTemplate].self, from: Data(childrenJSON.utf8))
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["name"] = name
        container["icon"] = icon.encodedJSONString()
        container["compatibility_json"] = compatibilityJSONString
        container["min_app_version"] = minAppVersion?.description
        container["entrypoint"] = entrypoint
        container["dependencies_json"] = dependenciesJSONString
        container["settings_json"] = settingsJSONString
        container["widgets_json"] = widgetsJSONString
        container["layout_json"] = layout.map { String(decoding: try! JSONEncoder().encode($0), as: UTF8.self) }
        container["children_json"] = String(decoding: try! JSONEncoder().encode(children), as: UTF8.self)
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }

    public func toJSON() -> [String: Any] {
        var out: [String: Any] = [
            "id": id.uuidString,
            "name": name,
            "icon": icon.toJSON(),
            "entrypoint": entrypoint,
            "dependencies": dependencies,
            "settings": settings.map(settingToJSON),
            "widgets": widgets.map { $0.toWireJSON() },
            "children": children.map { $0.toWireJSON() },
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "updated_at": ISO8601DateFormatter().string(from: updatedAt),
        ]
        if let obj = compatibilityJSONObject {
            out["compatibility"] = obj
        }
        if let minAppVersion {
            out["engines"] = ["luma": minAppVersion.engineRange]
        }
        if let layout {
            out["layout"] = layout.wireJSON
        }
        return out
    }

    public static func fromJSON(_ obj: [String: Any]) -> CustomInstrumentDef? {
        guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr),
            let name = obj["name"] as? String,
            let icon = InstrumentIcon.fromJSON(obj["icon"]),
            let entrypoint = obj["entrypoint"] as? String,
            let dependencies = obj["dependencies"] as? [String: String]
        else { return nil }
        let compatibility = parseCompatibility(obj["compatibility"])
        let minAppVersion = ((obj["engines"] as? [String: Any])?["luma"] as? String).flatMap(StoreVersion.least(inEngineRange:))
        let settings = parseSettings(obj["settings"])
        let widgets = parseWidgets(obj["widgets"])
        let wireLayout = obj["layout"]
        let layout = wireLayout.flatMap { InstrumentLayout.fromWireJSON($0, placing: widgets) }
        guard (wireLayout == nil) == (layout == nil) else { return nil }
        let wireChildren = (obj["children"] as? [[String: Any]]) ?? []
        let children = wireChildren.compactMap(InstrumentChildTemplate.fromWireJSON)
        guard children.count == wireChildren.count else { return nil }
        let isoFmt = ISO8601DateFormatter()
        let createdAt = (obj["created_at"] as? String).flatMap(isoFmt.date(from:)) ?? Date()
        let updatedAt = (obj["updated_at"] as? String).flatMap(isoFmt.date(from:)) ?? Date()
        return CustomInstrumentDef(
            id: id,
            name: name,
            icon: icon,
            compatibility: compatibility,
            minAppVersion: minAppVersion,
            entrypoint: entrypoint,
            dependencies: dependencies,
            settings: settings,
            widgets: widgets,
            layout: layout,
            children: children,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private var dependenciesJSONString: String {
        let data = try! JSONEncoder().encode(dependencies)
        return String(decoding: data, as: UTF8.self)
    }

    private var settingsJSONString: String {
        let data = try! JSONEncoder().encode(settings)
        return String(decoding: data, as: UTF8.self)
    }

    private var widgetsJSONString: String {
        let data = try! JSONEncoder().encode(widgets)
        return String(decoding: data, as: UTF8.self)
    }

    private var compatibilityJSONString: String {
        let data = try! JSONEncoder().encode(compatibility)
        return String(decoding: data, as: UTF8.self)
    }

    private var compatibilityJSONObject: [String: Any]? {
        guard !compatibility.isUniversal else { return nil }
        let data = try! JSONEncoder().encode(compatibility)
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func parseCompatibility(_ raw: Any?) -> InstrumentCompatibility {
        guard let obj = raw as? [String: Any],
            let data = try? JSONSerialization.data(withJSONObject: obj),
            let decoded = try? JSONDecoder().decode(InstrumentCompatibility.self, from: data)
        else {
            return .universal
        }
        return decoded
    }

    private static func parseSettings(_ raw: Any?) -> [Setting] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap(parseSetting)
    }

    private static func parseWidgets(_ raw: Any?) -> [InstrumentWidget] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap(InstrumentWidget.fromWireJSON)
    }

    private static func parseSetting(_ obj: [String: Any]) -> Setting? {
        guard let id = obj["id"] as? String, let name = obj["name"] as? String else { return nil }
        let schema = parseSettingSchema(obj["schema"]) ?? .boolean(default: false)
        let optional = (obj["optional"] as? Bool) ?? false
        let enabledByDefault = (obj["enabled_by_default"] as? Bool) ?? true
        return Setting(id: id, name: name, schema: schema, optional: optional, enabledByDefault: enabledByDefault)
    }

    private static func parseSettingSchema(_ raw: Any?) -> SettingSchema? {
        guard let wire = raw as? [String: Any] else { return nil }
        let obj = localSchema(wire)
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: obj)
        } catch {
            return nil
        }
        return try? JSONDecoder().decode(SettingSchema.self, from: data)
    }

    private func settingToJSON(_ setting: Setting) -> [String: Any] {
        var out: [String: Any] = [
            "id": setting.id,
            "name": setting.name,
            "optional": setting.optional,
            "enabled_by_default": setting.enabledByDefault,
        ]
        if let data = try? JSONEncoder().encode(setting.schema),
            let schemaObj = try? JSONSerialization.jsonObject(with: data)
        {
            out["schema"] = Self.wireSchema(schemaObj)
        }
        return out
    }

    private static func wireSchema(_ local: Any) -> Any {
        guard var schema = local as? [String: Any] else { return local }
        if let fields = schema["fields"] as? [[String: Any]] {
            schema["fields"] = fields.map { field -> [String: Any] in
                var wire = field
                wire["enabled_by_default"] = wire.removeValue(forKey: "enabledByDefault")
                wire["schema"] = wire["schema"].map(wireSchema)
                return wire
            }
        }
        schema["item"] = schema["item"].map(wireSchema)
        if schema["kind"] as? String == "array", let values = schema["default"] as? [[String: Any]] {
            schema["default"] = values.map(plainValue)
        }
        return schema
    }

    private static func plainValue(_ tagged: [String: Any]) -> Any {
        switch tagged["value"] {
        case let fields as [String: [String: Any]]: fields.mapValues(plainValue)
        case let items as [[String: Any]]: items.map(plainValue)
        case let value?: value
        case nil: NSNull()
        }
    }

    private static func localSchema(_ wire: Any) -> Any {
        guard var schema = wire as? [String: Any] else { return wire }
        if let fields = schema["fields"] as? [[String: Any]] {
            schema["fields"] = fields.map { field -> [String: Any] in
                var local = field
                local["enabledByDefault"] = local.removeValue(forKey: "enabled_by_default")
                local["schema"] = local["schema"].map(localSchema)
                return local
            }
        }
        schema["item"] = schema["item"].map(localSchema)
        if schema["kind"] as? String == "array", let item = schema["item"] as? [String: Any], let values = schema["default"] as? [Any] {
            schema["default"] = values.map { taggedValue($0, as: item) }
        }
        return schema
    }

    private static func taggedValue(_ plain: Any, as schema: [String: Any]) -> [String: Any] {
        switch schema["kind"] as? String {
        case "combo":
            return ["kind": "string", "value": plain]
        case "object":
            let fields = (schema["fields"] as? [[String: Any]]) ?? []
            let values = (plain as? [String: Any]) ?? [:]
            var tagged: [String: Any] = [:]
            for field in fields {
                guard let id = field["id"] as? String, let value = values[id], let fieldSchema = field["schema"] as? [String: Any] else { continue }
                tagged[id] = taggedValue(value, as: fieldSchema)
            }
            return ["kind": "object", "value": tagged]
        case "array":
            let item = (schema["item"] as? [String: Any]) ?? [:]
            return ["kind": "array", "value": ((plain as? [Any]) ?? []).map { taggedValue($0, as: item) }]
        case let kind:
            return ["kind": kind ?? "string", "value": plain]
        }
    }

    public mutating func normalize() {
        for i in settings.indices {
            settings[i].schema = CustomInstrumentDef.normalizedSchema(settings[i].schema)
            if case .boolean = settings[i].schema, settings[i].optional {
                settings[i].optional = false
            }
        }
    }

    private static func normalizedSchema(_ schema: SettingSchema) -> SettingSchema {
        switch schema {
        case .object(let fields):
            return .object(fields: fields.map(normalizedField))
        case .array(let item, let d):
            return .array(item: normalizedArrayItem(item), default: d)
        default:
            return schema
        }
    }

    private static func normalizedField(_ field: ObjectField) -> ObjectField {
        var copy = field
        copy.schema = normalizedSchema(field.schema)
        if case .boolean = copy.schema, copy.optional {
            copy.optional = false
        }
        return copy
    }

    private static func normalizedArrayItem(_ item: ArrayItemSchema) -> ArrayItemSchema {
        switch item {
        case .object(let fields):
            return .object(fields: fields.map(normalizedField))
        default:
            return item
        }
    }

    public static let defaultEntrypointFilename = "main.ts"

    public static func defaultEntrypointFiles(defID: UUID) -> [CustomInstrumentFile] {
        [CustomInstrumentFile(defID: defID, path: defaultEntrypointFilename, content: defaultEntrypointSource)]
    }

    public static let defaultEntrypointSource: String = """
        // A custom instrument is a regular Frida agent module. It runs in
        // the target process and exports an `instrument` object that the
        // host loads via the standard instrument lifecycle.
        //
        // create():    install your hooks; return updateConfig + dispose,
        //              plus onAction if your widgets declare actions or
        //              row actions, and onConsoleInput if you have a
        //              console widget.
        // dispose():   undo every side effect (detach listeners, revert
        //              replacements). Save will call this and then re-create
        //              with the new source.
        //
        // Settings declared in the sidebar show up on `config.settings`
        // typed exactly as you defined them. Accessing a setting you have
        // not declared is a type error.
        //
        // Widgets declared in the sidebar render in the instance pane and
        // are accessed via `ctx.widget(id)`:
        //   - counter:   setCounter({ value, unit?, delta? }), clear()
        //   - histogram: setHistogram(buckets),
        //                incrementBucket(label, by?), clear()
        //   - graph:     push({ series, x, y }), clear()
        //   - list:      upsertItem({ id, title, subtitle?, accessory? }),
        //                removeItem(id), clear()
        //   - table:     upsertRow({ id, cells }), removeRow(id), clear()
        //   - hex:       setHex({ bytes, baseAddress? }), clear()
        //   - console:   appendOutput(text), appendError(text),
        //                appendValue(value) — renders any JS value
        //                (objects, NativePointer, ArrayBuffer, …) using
        //                the same inspector the REPL uses,
        //                appendConsole({ kind, text }), clear()
        //   - view:      setState(value, data?), sendEvent(value, data?),
        //                clear() — shown by a class from the instrument's
        //                Smalltalk (.st files), which may answer through
        //                onViewMessage({ widget, value, data })
        //
        // A widget's actions are buttons in its header, and a list's or
        // table's row actions are buttons on each row; either invokes
        // onAction({ widget, action, item }) on the handle, `item` being
        // the row's id for a row action and absent otherwise. Luma never
        // clears a widget by itself: offer an action that calls clear()
        // when the user should be able to. A widget with actions also has
        // setActionEnabled(action, enabled) to gray one out while it
        // cannot run; every action is enabled again each time create()
        // runs, and clear() leaves them as they are. Submissions from a console
        // widget invoke
        //   onConsoleInput({ widget, entryId, text }, respond)
        // and `respond.output` / `respond.error` / `respond.value` post
        // entries that are visually grouped with the originating input.
        // For unsolicited output, call appendOutput / appendError /
        // appendValue on the widget directly. The `widget` and `action`
        // fields are narrowed to the ids you declared. The `restored`
        // argument carries the last snapshot for each widget whose
        // Persistence is set to Session — widgets left at None do not
        // appear on `restored`.
        //
        // The example below assumes:
        //   - one setting `logStack` (Boolean)
        //   - one graph widget `opens` with series `length` and
        //     Persistence = Session (required for `restored.opens`
        //     to type-check)
        //   - one list widget `paths` with row action `bookmark`
        //   - one console widget `repl`
        // Until you add them, the lines referencing them are type
        // errors — add them via right-click → Settings… / Widgets…,
        // or delete the corresponding lines.

        export const instrument: CustomInstrument = {
            create(ctx, config, restored) {
                let current = config;
                const listeners: InvocationListener[] = [];
                const bookmarks = new Set<string>();
                let count = restored.opens.points.length;

                if (Process.platform !== "windows") {
                    listeners.push(Interceptor.attach(Module.getGlobalExportByName("open"), {
                        onEnter(args) {
                            const path = args[0].readUtf8String()!;
                            ctx.emit({ syscall: "open", path });
                            ctx.widget("opens").push({ series: "length", x: ++count, y: path.length });
                            ctx.widget("paths").upsertItem({ id: path, title: path });
                            if (current.settings.logStack) {
                                ctx.emit({ stack: this.context.sp.readByteArray(64) });
                            }
                        }
                    }));
                }

                return {
                    updateConfig(next) {
                        current = next;
                    },
                    onAction(action) {
                        if (action.widget === "paths" && action.action === "bookmark") {
                            bookmarks.add(action.item);
                            ctx.emit({ bookmarked: action.item });
                        }
                    },
                    onConsoleInput({ widget, text }, respond) {
                        if (widget === "repl") {
                            respond.output(`echo: ${text}`);
                        }
                    },
                    dispose() {
                        for (const l of listeners) {
                            l.detach();
                        }
                    }
                };
            }
        };
        """
}
