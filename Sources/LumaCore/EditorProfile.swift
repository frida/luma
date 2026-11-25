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

    public var syntax: SourceSyntax {
        switch languageId {
        case "hexpat":
            return .pattern
        case "smalltalk":
            return .smalltalk
        case "plaintext":
            return .plainText
        default:
            return .typeScript
        }
    }

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

    public static func pattern(_ source: PatternSource) -> EditorProfile {
        EditorProfile(languageId: "hexpat", activePath: source.workspacePath, readOnly: source.origin != .project)
    }

    public static func patternPreview() -> EditorProfile {
        EditorProfile(languageId: "hexpat", activePath: "patterns/preview.hexpat")
    }

    public static func fridaCustomInstrument(
        packages: [InstalledPackage],
        def: CustomInstrumentDef? = nil,
        files: [CustomInstrumentFile] = [],
        activePath: String? = nil
    ) -> EditorProfile {
        let projectFiles = files.compactMap(languageServerFile(of:))
        switch activePath.map(SourceSyntax.init(path:)) ?? .typeScript {
        case .pattern:
            return EditorProfile(
                languageId: "hexpat",
                projectFiles: projectFiles.filter { $0.languageId == "hexpat" },
                activePath: activePath)
        case .smalltalk:
            return EditorProfile(
                languageId: "smalltalk",
                projectFiles: files.compactMap(smalltalkFile(of:)).filter { $0.path != activePath },
                activePath: activePath)
        case .plainText:
            return EditorProfile(languageId: "plaintext", activePath: activePath)
        case .typeScript:
            return EditorProfile(
                languageId: "typescript",
                projectFiles: projectFiles,
                activePath: activePath,
                ambientDeclarations: [CustomInstrumentTypings.ambient]
                    + (def.flatMap(CustomInstrumentTypings.settingMap(for:)).map { [$0] } ?? [])
                    + PackageAliasTypings.declarations(for: packages)
            )
        }
    }

    private static func languageServerFile(of file: CustomInstrumentFile) -> EditorProjectFile? {
        let path = CustomInstrumentFile.workspaceRelativePath(defID: file.defID, path: file.path)
        switch SourceSyntax(path: file.path) {
        case .typeScript:
            return EditorProjectFile(path: path, text: file.content)
        case .pattern:
            return EditorProjectFile(path: path, text: file.content, languageId: "hexpat")
        case .smalltalk, .plainText:
            return nil
        }
    }

    private static func smalltalkFile(of file: CustomInstrumentFile) -> EditorProjectFile? {
        guard SourceSyntax(path: file.path) == .smalltalk else { return nil }
        let path = CustomInstrumentFile.workspaceRelativePath(defID: file.defID, path: file.path)
        return EditorProjectFile(path: path, text: file.content, languageId: "smalltalk")
    }
}

public enum SourceSyntax: Hashable, Sendable {
    case typeScript
    case pattern
    case smalltalk
    case plainText

    public init(path: String) {
        let pathExtension = (path as NSString).pathExtension.lowercased()
        if PatternSource.Kind(path: path) != nil {
            self = .pattern
        } else if Self.scriptExtensions.contains(pathExtension) {
            self = .typeScript
        } else if pathExtension == "st" {
            self = .smalltalk
        } else {
            self = .plainText
        }
    }

    public var isReadByLanguageServer: Bool {
        switch self {
        case .typeScript, .pattern:
            return true
        case .smalltalk, .plainText:
            return false
        }
    }

    private static let scriptExtensions: Set<String> = ["ts", "mts", "cts", "tsx", "js", "mjs", "cjs", "jsx"]

    public func tokenize(_ text: String) -> [TypeScriptToken] {
        switch self {
        case .typeScript:
            return TypeScriptLexer.tokenize(text)
        case .pattern:
            return PatternLexer.tokenize(text)
        case .smalltalk, .plainText:
            return []
        }
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

        declare interface CustomInstrumentListWidget {
            upsertItem(item: { id: string, title: string, subtitle?: string, accessory?: string }): void;
            removeItem(id: string): void;
            clear(): void;
        }

        declare interface CustomInstrumentTableWidget<Column extends string> {
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

        declare type CustomInstrumentViewData = ArrayBuffer | ArrayBufferView | number[];

        declare interface CustomInstrumentViewWidget {
            setState(value: unknown, data?: CustomInstrumentViewData | null): void;
            sendEvent(value: unknown, data?: CustomInstrumentViewData | null): void;
            clear(): void;
        }

        declare interface CustomInstrumentWidgetActions<Action extends string> {
            setActionEnabled(action: Action, enabled: boolean): void;
        }

        declare interface CustomInstrumentWidgetMap {
        }

        declare interface CustomInstrumentActionMap {
        }

        declare type CustomInstrumentAction = CustomInstrumentActionMap[keyof CustomInstrumentActionMap];

        declare type CustomInstrumentConsoleInput = {
            [K in keyof CustomInstrumentWidgetMap]:
                CustomInstrumentWidgetMap[K] extends CustomInstrumentConsoleWidget
                    ? { widget: K; entryId: string; text: string }
                    : never
        }[keyof CustomInstrumentWidgetMap];

        declare type CustomInstrumentViewMessage = {
            [K in keyof CustomInstrumentWidgetMap]:
                CustomInstrumentWidgetMap[K] extends CustomInstrumentViewWidget
                    ? { widget: K; value: unknown; data: ArrayBuffer | null; from?: { id: string; name: string } }
                    : never
        }[keyof CustomInstrumentWidgetMap];

        declare interface CustomInstrumentConsoleResponder {
            output(text: string): void;
            error(text: string): void;
            value(v: unknown): void;
            image(image: CustomInstrumentConsoleImage): void;
        }

        declare type CustomSettingValue = boolean | number | string | CustomSettingValue[] | { [name: string]: CustomSettingValue };

        declare interface CustomInstrumentSettingMap {
        }

        declare interface CustomInstrumentConfig {
            settings: CustomInstrumentSettingMap;
        }

        declare interface CustomInstrumentHandle {
            updateConfig?(config: CustomInstrumentConfig): void | Promise<void>;
            onAction?(action: CustomInstrumentAction): void | Promise<void>;
            onConsoleInput?(
                input: CustomInstrumentConsoleInput,
                respond: CustomInstrumentConsoleResponder
            ): void | Promise<void>;
            onViewMessage?(message: CustomInstrumentViewMessage): void | Promise<void>;
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

        declare interface CustomInstrumentViewSnapshot {
            state: unknown | null;
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

    public static func settingMap(for def: CustomInstrumentDef) -> AmbientDeclarations? {
        guard !def.settings.isEmpty || !def.widgets.isEmpty else { return nil }
        return AmbientDeclarations(
            content: defScopedDeclarations(for: def),
            fileName: "custom-instrument-\(def.id.uuidString).d.ts"
        )
    }

    public static func compilerTypings(for def: CustomInstrumentDef, packages: [InstalledPackage]) -> [AmbientDeclarations] {
        [ambient] + (settingMap(for: def).map { [$0] } ?? []) + PackageAliasTypings.declarations(for: packages)
    }

    public static func declarations(for def: CustomInstrumentDef) -> String {
        ([ambient.content] + (settingMap(for: def).map { [$0.content] } ?? []))
            .joined(separator: "\n\n")
    }

    public static func defScopedDeclarations(for def: CustomInstrumentDef) -> String {
        var sections: [String] = []
        if !def.settings.isEmpty {
            sections.append(settingMapDeclarations(for: def))
        }
        if !def.widgets.isEmpty {
            sections.append(widgetMapDeclarations(for: def))
        }
        let actingWidgets = def.widgets.filter { !$0.actions.isEmpty || !$0.kind.rowActions.isEmpty }
        if !actingWidgets.isEmpty {
            sections.append(actionMapDeclarations(for: actingWidgets))
        }
        let persistentWidgets = def.widgets.filter { $0.persistence == .session }
        if !persistentWidgets.isEmpty {
            sections.append(restoredStateDeclarations(for: persistentWidgets))
        }
        return sections.joined(separator: "\n\n")
    }

    public static func settingMapDeclarations(for def: CustomInstrumentDef) -> String {
        var lines: [String] = ["declare interface CustomInstrumentSettingMap {"]
        for setting in def.settings {
            let optionalMark = setting.optional ? "?" : ""
            lines.append("    /** \(jsDocText(setting.name)) */")
            lines.append("    \(propertyKey(setting.id))\(optionalMark): \(typeScriptType(for: setting.schema, optional: setting.optional));")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    public static func widgetMapDeclarations(for def: CustomInstrumentDef) -> String {
        var lines: [String] = ["declare interface CustomInstrumentWidgetMap {"]
        for widget in def.widgets {
            lines.append("    /** \(jsDocText(widget.label)) */")
            lines.append("    \(propertyKey(widget.id)): \(widgetType(for: widget));")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    public static func actionMapDeclarations(for actingWidgets: [InstrumentWidget]) -> String {
        var lines: [String] = ["declare interface CustomInstrumentActionMap {"]
        for widget in actingWidgets {
            let widgetLiteral = jsStringLiteral(widget.id)
            var variants: [String] = []
            if !widget.actions.isEmpty {
                variants.append("{ widget: \(widgetLiteral); action: \(stringLiteralUnion(widget.actions.map(\.id))); item?: undefined }")
            }
            if !widget.kind.rowActions.isEmpty {
                variants.append("{ widget: \(widgetLiteral); action: \(stringLiteralUnion(widget.kind.rowActions.map(\.id))); item: string }")
            }
            lines.append("    \(propertyKey(widget.id)): \(variants.joined(separator: " | "));")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    public static func restoredStateDeclarations(for persistentWidgets: [InstrumentWidget]) -> String {
        var lines: [String] = ["declare interface CustomInstrumentRestoredState {"]
        for widget in persistentWidgets {
            lines.append("    /** \(jsDocText(widget.label)) */")
            lines.append("    \(propertyKey(widget.id)): \(snapshotType(for: widget.kind));")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func widgetType(for widget: InstrumentWidget) -> String {
        let kindType = widgetType(for: widget.kind)
        guard !widget.actions.isEmpty else { return kindType }
        return "\(kindType) & CustomInstrumentWidgetActions<\(stringLiteralUnion(widget.actions.map(\.id)))>"
    }

    private static func widgetType(for kind: InstrumentWidget.Kind) -> String {
        switch kind {
        case .counter:
            return "CustomInstrumentCounterWidget"
        case .histogram:
            return "CustomInstrumentHistogramWidget"
        case .graph(let cfg):
            return "CustomInstrumentGraphWidget<\(stringLiteralUnion(cfg.series.map(\.id)))>"
        case .list:
            return "CustomInstrumentListWidget"
        case .table(let cfg):
            return "CustomInstrumentTableWidget<\(stringLiteralUnion(cfg.columns.map(\.id)))>"
        case .hex:
            return "CustomInstrumentHexWidget"
        case .console:
            return "CustomInstrumentConsoleWidget"
        case .view:
            return "CustomInstrumentViewWidget"
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
        case .view:
            return "CustomInstrumentViewSnapshot"
        }
    }

    private static func stringLiteralUnion(_ ids: [String]) -> String {
        guard !ids.isEmpty else { return "never" }
        return ids.map(jsStringLiteral).joined(separator: " | ")
    }

    private static func propertyKey(_ id: String) -> String {
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

    private static func typeScriptType(for schema: SettingSchema, optional: Bool) -> String {
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
            return "/** \(jsDocText(field.name)) */ \(propertyKey(field.id))\(optionalMark): \(typeScriptType(for: field.schema, optional: field.optional))"
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
