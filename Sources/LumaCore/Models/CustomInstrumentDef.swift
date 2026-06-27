import Foundation
import GRDB

public struct CustomInstrumentDef: Codable, Identifiable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "custom_instrument_def"

    public var id: UUID
    public var name: String
    public var icon: InstrumentIcon
    public var compatibility: InstrumentCompatibility
    public var entrypoint: String
    public var features: [Feature]
    public var widgets: [InstrumentWidget]
    public var createdAt: Date
    public var updatedAt: Date

    public struct Feature: Codable, Identifiable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var schema: FeatureSchema
        public var optional: Bool
        public var enabledByDefault: Bool

        public init(
            id: String,
            name: String,
            schema: FeatureSchema = .boolean(default: true),
            optional: Bool = true,
            enabledByDefault: Bool = true
        ) {
            self.id = id
            self.name = name
            self.schema = schema
            self.optional = optional
            self.enabledByDefault = enabledByDefault
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        icon: InstrumentIcon = .symbolic(InstrumentIconCatalog.default.id),
        compatibility: InstrumentCompatibility = .universal,
        entrypoint: String,
        features: [Feature] = [],
        widgets: [InstrumentWidget] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.compatibility = compatibility
        self.entrypoint = entrypoint
        self.features = features
        self.widgets = widgets
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(row: Row) throws {
        id = UUID(uuidString: row["id"])!
        name = row["name"]
        icon = InstrumentIcon.decodedJSONString(row["icon"])
        let compatibilityJSON: String = row["compatibility_json"]
        compatibility = try JSONDecoder().decode(InstrumentCompatibility.self, from: Data(compatibilityJSON.utf8))
        entrypoint = row["entrypoint"]
        let featuresJSON: String = row["features_json"]
        features = try JSONDecoder().decode([Feature].self, from: Data(featuresJSON.utf8))
        let widgetsJSON: String = row["widgets_json"]
        widgets = try JSONDecoder().decode([InstrumentWidget].self, from: Data(widgetsJSON.utf8))
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["name"] = name
        container["icon"] = icon.encodedJSONString()
        container["compatibility_json"] = compatibilityJSONString
        container["entrypoint"] = entrypoint
        container["features_json"] = featuresJSONString
        container["widgets_json"] = widgetsJSONString
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }

    public func toJSON() -> [String: Any] {
        var out: [String: Any] = [
            "id": id.uuidString,
            "name": name,
            "icon": icon.toJSON(),
            "entrypoint": entrypoint,
            "features": features.map(featureToJSON),
            "widgets": widgetsJSONArray,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "updated_at": ISO8601DateFormatter().string(from: updatedAt),
        ]
        if let obj = compatibilityJSONObject {
            out["compatibility"] = obj
        }
        return out
    }

    public static func fromJSON(_ obj: [String: Any]) -> CustomInstrumentDef? {
        guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr),
            let name = obj["name"] as? String,
            let icon = InstrumentIcon.fromJSON(obj["icon"]),
            let entrypoint = obj["entrypoint"] as? String
        else { return nil }
        let compatibility = parseCompatibility(obj["compatibility"])
        let features = parseFeatures(obj["features"])
        let widgets = parseWidgets(obj["widgets"])
        let isoFmt = ISO8601DateFormatter()
        let createdAt = (obj["created_at"] as? String).flatMap(isoFmt.date(from:)) ?? Date()
        let updatedAt = (obj["updated_at"] as? String).flatMap(isoFmt.date(from:)) ?? Date()
        return CustomInstrumentDef(
            id: id,
            name: name,
            icon: icon,
            compatibility: compatibility,
            entrypoint: entrypoint,
            features: features,
            widgets: widgets,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private var featuresJSONString: String {
        let data = try! JSONEncoder().encode(features)
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

    private static func parseCompatibility(_ raw: Any?) -> InstrumentCompatibility {
        guard let obj = raw as? [String: Any],
            let data = try? JSONSerialization.data(withJSONObject: obj),
            let decoded = try? JSONDecoder().decode(InstrumentCompatibility.self, from: data)
        else {
            return .universal
        }
        return decoded
    }

    private var widgetsJSONArray: [Any] {
        let data = try! JSONEncoder().encode(widgets)
        return try! JSONSerialization.jsonObject(with: data) as! [Any]
    }

    private static func parseFeatures(_ raw: Any?) -> [Feature] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap(parseFeature)
    }

    private static func parseWidgets(_ raw: Any?) -> [InstrumentWidget] {
        guard let arr = raw as? [Any],
            let data = try? JSONSerialization.data(withJSONObject: arr),
            let widgets = try? JSONDecoder().decode([InstrumentWidget].self, from: data)
        else { return [] }
        return widgets
    }

    private static func parseFeature(_ obj: [String: Any]) -> Feature? {
        guard let id = obj["id"] as? String, let name = obj["name"] as? String else { return nil }
        let schema = parseFeatureSchema(obj["schema"]) ?? .boolean(default: false)
        let optional = (obj["optional"] as? Bool) ?? true
        let enabledByDefault = (obj["enabled_by_default"] as? Bool) ?? true
        return Feature(id: id, name: name, schema: schema, optional: optional, enabledByDefault: enabledByDefault)
    }

    private static func parseFeatureSchema(_ raw: Any?) -> FeatureSchema? {
        guard let obj = raw as? [String: Any] else { return nil }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: obj)
        } catch {
            return nil
        }
        return try? JSONDecoder().decode(FeatureSchema.self, from: data)
    }

    private func featureToJSON(_ feature: Feature) -> [String: Any] {
        var out: [String: Any] = [
            "id": feature.id,
            "name": feature.name,
            "optional": feature.optional,
            "enabled_by_default": feature.enabledByDefault,
        ]
        if let data = try? JSONEncoder().encode(feature.schema),
            let schemaObj = try? JSONSerialization.jsonObject(with: data)
        {
            out["schema"] = schemaObj
        }
        return out
    }

    public mutating func normalize() {
        for i in features.indices {
            features[i].schema = CustomInstrumentDef.normalizedSchema(features[i].schema)
            if case .boolean = features[i].schema, features[i].optional {
                features[i].optional = false
            }
        }
    }

    private static func normalizedSchema(_ schema: FeatureSchema) -> FeatureSchema {
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
        //              plus onAction if your list or table widgets declare
        //              actions, and onConsoleInput if you have a console
        //              widget.
        // dispose():   undo every side effect (detach listeners, revert
        //              replacements). Save will call this and then re-create
        //              with the new source.
        //
        // Features declared in the sidebar show up on `config.features`
        // typed exactly as you defined them. Accessing a feature you have
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
        //
        // Action buttons on a list or table widget invoke onAction({
        // widget, action, item }) on the handle. Submissions from a
        // console widget invoke
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
        //   - one feature `logStack` (Boolean)
        //   - one graph widget `opens` with series `length` and
        //     Persistence = Session (required for `restored.opens`
        //     to type-check)
        //   - one list widget `paths` with action `bookmark`
        //   - one console widget `repl`
        // Until you add them, the lines referencing them are type
        // errors — add them via right-click → Features… / Widgets…,
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
                            if (current.features.logStack) {
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
