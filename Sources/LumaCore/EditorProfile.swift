import Foundation

public struct AmbientDeclarations: Sendable, Hashable {
    public var content: String
    public var fileName: String

    public init(content: String, fileName: String) {
        self.content = content
        self.fileName = fileName
    }
}

public struct EditorProjectFile: Sendable, Equatable, Hashable {
    public var path: String
    public var text: String
    public var languageId: String?

    public init(path: String, text: String, languageId: String? = nil) {
        self.path = path
        self.text = text
        self.languageId = languageId
    }
}

public struct EditorProfile: Sendable, Equatable {
    public var languageId: String
    public var projectFiles: [EditorProjectFile]
    public var activePath: String?
    public var readOnly: Bool
    public var ambientDeclarations: [AmbientDeclarations]

    public init(
        languageId: String = "javascript",
        projectFiles: [EditorProjectFile] = [],
        activePath: String? = nil,
        readOnly: Bool = false,
        ambientDeclarations: [AmbientDeclarations] = []
    ) {
        self.languageId = languageId
        self.projectFiles = projectFiles
        self.activePath = activePath
        self.readOnly = readOnly
        self.ambientDeclarations = ambientDeclarations
    }
}

extension EditorProfile {
    public static func fridaTracerHook(packages: [InstalledPackage]) -> EditorProfile {
        EditorProfile(
            languageId: "typescript",
            ambientDeclarations: [TracerTypings.handler] + PackageAliasTypings.declarations(for: packages)
        )
    }

    public static func fridaCodeShare(readOnly: Bool = false) -> EditorProfile {
        EditorProfile(languageId: "javascript", readOnly: readOnly)
    }

    public static func fridaCustomInstrument(
        packages: [InstalledPackage],
        def: CustomInstrumentDef? = nil,
        files: [CustomInstrumentFile] = [],
        activePath: String? = nil
    ) -> EditorProfile {
        EditorProfile(
            languageId: "typescript",
            projectFiles: files.map { file in
                EditorProjectFile(
                    path: CustomInstrumentFile.workspaceRelativePath(defID: file.defID, path: file.path),
                    text: file.content
                )
            },
            activePath: activePath,
            ambientDeclarations: [CustomInstrumentTypings.ambient]
                + (def.flatMap(CustomInstrumentTypings.featureMap(for:)).map { [$0] } ?? [])
                + PackageAliasTypings.declarations(for: packages)
        )
    }
}

public enum CustomInstrumentTypings {
    public static let ambientDeclarations = #"""
        declare interface CustomInstrumentContext {
            emit(value: unknown): void;
            widget<K extends keyof CustomInstrumentWidgetMap>(id: K): CustomInstrumentWidgetMap[K];
        }

        declare interface CustomInstrumentCounterWidget {
            setCounter(value: { value: number, unit?: string, delta?: number }): void;
            clear(): void;
        }

        declare interface CustomInstrumentHistogramWidget {
            setHistogram(buckets: Array<{ label: string, count: number }>): void;
            incrementBucket(label: string, by?: number): void;
            clear(): void;
        }

        declare interface CustomInstrumentGraphWidget<Series extends string> {
            push(point: { series: Series, x: number, y: number }): void;
            clear(): void;
        }

        declare interface CustomInstrumentListWidget<Action extends string> {
            upsertItem(item: { id: string, title: string, subtitle?: string, accessory?: string }): void;
            removeItem(id: string): void;
            clear(): void;
        }

        declare interface CustomInstrumentTableWidget<Column extends string, Action extends string> {
            upsertRow(row: { id: string, cells: { [K in Column]: string } }): void;
            removeRow(id: string): void;
            clear(): void;
        }

        declare interface CustomInstrumentHexWidget {
            setHex(state: { bytes: ArrayBuffer | number[], baseAddress?: number | string }): void;
            clear(): void;
        }

        declare interface CustomInstrumentConsoleImage {
            bytes: ArrayBuffer | Uint8Array | number[];
            mediaType: string;
            width: number;
            height: number;
            text?: string;
        }

        declare interface CustomInstrumentConsoleWidget {
            appendOutput(text: string): void;
            appendError(text: string): void;
            appendValue(value: unknown): void;
            appendImage(image: CustomInstrumentConsoleImage): void;
            appendConsole(entry: { id?: string, kind: "input" | "output" | "error", text: string }): void;
            clear(): void;
        }

        declare interface CustomInstrumentWidgetMap {
        }

        declare type CustomInstrumentAction = {
            [K in keyof CustomInstrumentWidgetMap]:
                CustomInstrumentWidgetMap[K] extends CustomInstrumentListWidget<infer A>
                    ? { widget: K; action: A; item: string }
                : CustomInstrumentWidgetMap[K] extends CustomInstrumentTableWidget<any, infer A>
                    ? { widget: K; action: A; item: string }
                    : never
        }[keyof CustomInstrumentWidgetMap];

        declare type CustomInstrumentConsoleInput = {
            [K in keyof CustomInstrumentWidgetMap]:
                CustomInstrumentWidgetMap[K] extends CustomInstrumentConsoleWidget
                    ? { widget: K; entryId: string; text: string }
                    : never
        }[keyof CustomInstrumentWidgetMap];

        declare interface CustomInstrumentConsoleResponder {
            output(text: string): void;
            error(text: string): void;
            value(v: unknown): void;
            image(image: CustomInstrumentConsoleImage): void;
        }

        declare type CustomFeatureValue = boolean | number | string | CustomFeatureValue[] | { [name: string]: CustomFeatureValue };

        declare interface CustomInstrumentFeatureMap {
        }

        declare interface CustomInstrumentConfig {
            features: CustomInstrumentFeatureMap;
        }

        declare interface CustomInstrumentHandle {
            updateConfig?(config: CustomInstrumentConfig): void | Promise<void>;
            onAction?(action: CustomInstrumentAction): void | Promise<void>;
            onConsoleInput?(
                input: CustomInstrumentConsoleInput,
                respond: CustomInstrumentConsoleResponder
            ): void | Promise<void>;
            dispose?(): void | Promise<void>;
        }

        declare interface CustomInstrumentCounterSnapshot {
            counter: { value: number; unit?: string; delta?: number } | null;
        }

        declare interface CustomInstrumentHistogramSnapshot {
            buckets: Array<{ label: string; count: number }>;
        }

        declare interface CustomInstrumentGraphSnapshot<Series extends string> {
            points: Array<{ series: Series; x: number; y: number }>;
        }

        declare interface CustomInstrumentListSnapshot {
            items: Array<{ id: string; title: string; subtitle?: string; accessory?: string }>;
        }

        declare interface CustomInstrumentTableSnapshot<Column extends string> {
            rows: Array<{ id: string; cells: { [K in Column]: string } }>;
        }

        declare interface CustomInstrumentHexSnapshot {
            hex: { bytes: string; base_address: number } | null;
        }

        declare interface CustomInstrumentConsoleSnapshot {
            entries: Array<{ id: string; kind: "input" | "output" | "error"; text: string }>;
        }

        declare interface CustomInstrumentRestoredState {
        }

        declare interface CustomInstrument {
            create(
                ctx: CustomInstrumentContext,
                config: CustomInstrumentConfig,
                restored: CustomInstrumentRestoredState,
            ): CustomInstrumentHandle | Promise<CustomInstrumentHandle>;
        }
        """#

    public static let ambient = AmbientDeclarations(
        content: ambientDeclarations,
        fileName: "custom-instrument.d.ts"
    )

    public static func featureMap(for def: CustomInstrumentDef) -> AmbientDeclarations? {
        guard !def.features.isEmpty || !def.widgets.isEmpty else { return nil }
        return AmbientDeclarations(
            content: defScopedDeclarations(for: def),
            fileName: "custom-instrument-\(def.id.uuidString).d.ts"
        )
    }

    public static func defScopedDeclarations(for def: CustomInstrumentDef) -> String {
        var sections: [String] = []
        if !def.features.isEmpty {
            sections.append(featureMapDeclarations(for: def))
        }
        if !def.widgets.isEmpty {
            sections.append(widgetMapDeclarations(for: def))
        }
        let persistentWidgets = def.widgets.filter { $0.persistence == .session }
        if !persistentWidgets.isEmpty {
            sections.append(restoredStateDeclarations(for: persistentWidgets))
        }
        return sections.joined(separator: "\n\n")
    }

    public static func featureMapDeclarations(for def: CustomInstrumentDef) -> String {
        var lines: [String] = ["declare interface CustomInstrumentFeatureMap {"]
        for feature in def.features {
            let optionalMark = feature.optional ? "?" : ""
            lines.append("    /** \(jsDocText(feature.name)) */")
            lines.append("    \(featureKey(feature.id))\(optionalMark): \(typeScriptType(for: feature.schema, optional: feature.optional));")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    public static func widgetMapDeclarations(for def: CustomInstrumentDef) -> String {
        var lines: [String] = ["declare interface CustomInstrumentWidgetMap {"]
        for widget in def.widgets {
            lines.append("    /** \(jsDocText(widget.name)) */")
            lines.append("    \(featureKey(widget.id)): \(widgetType(for: widget.kind));")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    public static func restoredStateDeclarations(for persistentWidgets: [InstrumentWidget]) -> String {
        var lines: [String] = ["declare interface CustomInstrumentRestoredState {"]
        for widget in persistentWidgets {
            lines.append("    /** \(jsDocText(widget.name)) */")
            lines.append("    \(featureKey(widget.id)): \(snapshotType(for: widget.kind));")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func widgetType(for kind: InstrumentWidget.Kind) -> String {
        switch kind {
        case .counter:
            return "CustomInstrumentCounterWidget"
        case .histogram:
            return "CustomInstrumentHistogramWidget"
        case .graph(let cfg):
            return "CustomInstrumentGraphWidget<\(stringLiteralUnion(cfg.series.map(\.id)))>"
        case .list(let cfg):
            return "CustomInstrumentListWidget<\(stringLiteralUnion(cfg.actions.map(\.id)))>"
        case .table(let cfg):
            return "CustomInstrumentTableWidget<\(stringLiteralUnion(cfg.columns.map(\.id))), \(stringLiteralUnion(cfg.actions.map(\.id)))>"
        case .hex:
            return "CustomInstrumentHexWidget"
        case .console:
            return "CustomInstrumentConsoleWidget"
        }
    }

    private static func snapshotType(for kind: InstrumentWidget.Kind) -> String {
        switch kind {
        case .counter:
            return "CustomInstrumentCounterSnapshot"
        case .histogram:
            return "CustomInstrumentHistogramSnapshot"
        case .graph(let cfg):
            return "CustomInstrumentGraphSnapshot<\(stringLiteralUnion(cfg.series.map(\.id)))>"
        case .list:
            return "CustomInstrumentListSnapshot"
        case .table(let cfg):
            return "CustomInstrumentTableSnapshot<\(stringLiteralUnion(cfg.columns.map(\.id)))>"
        case .hex:
            return "CustomInstrumentHexSnapshot"
        case .console:
            return "CustomInstrumentConsoleSnapshot"
        }
    }

    private static func stringLiteralUnion(_ ids: [String]) -> String {
        guard !ids.isEmpty else { return "never" }
        return ids.map(jsStringLiteral).joined(separator: " | ")
    }

    private static func featureKey(_ id: String) -> String {
        isValidJSIdentifier(id) ? id : jsStringLiteral(id)
    }

    private static func isValidJSIdentifier(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        guard first.isLetter || first == "_" || first == "$" else { return false }
        for c in s.dropFirst() {
            guard c.isLetter || c.isNumber || c == "_" || c == "$" else { return false }
        }
        return true
    }

    private static func typeScriptType(for schema: FeatureSchema, optional: Bool) -> String {
        switch schema {
        case .boolean: return optional ? "true" : "boolean"
        case .int, .uint, .double: return "number"
        case .string, .regex: return "string"
        case .combo(let choices, _):
            return comboType(choices: choices)
        case .object(let fields):
            return objectType(fields: fields)
        case .array(let item, _):
            return "(\(typeScriptArrayItemType(for: item)))[]"
        }
    }

    private static func typeScriptArrayItemType(for item: ArrayItemSchema) -> String {
        switch item {
        case .boolean: return "boolean"
        case .int, .uint, .double: return "number"
        case .string, .regex: return "string"
        case .combo(let choices): return comboType(choices: choices)
        case .object(let fields): return objectType(fields: fields)
        }
    }

    private static func objectType(fields: [ObjectField]) -> String {
        guard !fields.isEmpty else { return "{}" }
        let entries = fields.map { field in
            let optionalMark = field.optional ? "?" : ""
            return "/** \(jsDocText(field.name)) */ \(featureKey(field.id))\(optionalMark): \(typeScriptType(for: field.schema, optional: field.optional))"
        }
        return "{ \(entries.joined(separator: "; ")) }"
    }

    private static func comboType(choices: [ComboChoice]) -> String {
        guard !choices.isEmpty else { return "string" }
        return choices.map { jsStringLiteral($0.id) }.joined(separator: " | ")
    }

    private static func jsStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func jsDocText(_ s: String) -> String {
        s.replacingOccurrences(of: "*/", with: "*\\/")
    }
}

/// Ambient TypeScript declarations injected into tracer hook editors so
/// `defineHandler({...})` autocompletes correctly.
public enum TracerTypings {
    public static let handlerDeclarations = #"""
        export {};

        declare global {
            function defineHandler(h: Handler): void;

            type Handler = FunctionHandlers | InstructionHandler;

            interface FunctionHandlers {
                onEnter?: EnterHandler;
                onLeave?: LeaveHandler;
            }

            type EnterHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
            type LeaveHandler = (this: InvocationContext, log: LogHandler, retval: InvocationReturnValue) => any;
            type InstructionHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
            type LogHandler = (...args: any[]) => void;
        }
        """#

    public static let handler = AmbientDeclarations(
        content: handlerDeclarations,
        fileName: "tracer.d.ts"
    )
}
