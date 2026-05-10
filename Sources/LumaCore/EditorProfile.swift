import Foundation

/// Editor color theme.
public enum EditorTheme: String, Sendable, Codable {
    case light
    case dark
}

/// TypeScript `target` compiler option. Raw values match Monaco's enum.
public enum EditorScriptTarget: Int, Sendable, Codable {
    case es5    = 1
    case es2015 = 2
    case es2016 = 3
    case es2017 = 4
    case es2018 = 5
    case es2019 = 6
    case es2020 = 7
    case es2021 = 8
    case es2022 = 9
    case es2023 = 10
    case es2024 = 11
    case esNext = 99
}

/// TypeScript `module` compiler option. Raw values match Monaco's enum.
public enum EditorModuleKind: Int, Sendable, Codable {
    case commonJS = 1
    case amd      = 2
    case umd      = 3
    case system   = 4
    case es2015   = 5
    case es2020   = 6
    case es2022   = 7
    case esNext   = 99
    case node16   = 100
    case node18   = 101
    case node20   = 102
    case nodeNext = 199
}

/// TypeScript `moduleResolution` compiler option. Raw values match Monaco's enum.
public enum EditorModuleResolutionKind: Int, Sendable, Codable {
    case classic  = 1
    case nodeJs   = 2
    case node16   = 3
    case nodeNext = 99
    case bundler  = 100
}

/// TypeScript compiler options used to configure Monaco's `typescript`
/// language service. Mirrors a subset of `ts.CompilerOptions`.
public struct EditorCompilerOptions: Sendable, Equatable, Codable {
    public var target: EditorScriptTarget?
    public var lib: [String]?
    public var module: EditorModuleKind?
    public var moduleResolution: EditorModuleResolutionKind?
    public var typeRoots: [String]?
    public var strict: Bool?

    public init(
        target: EditorScriptTarget? = nil,
        lib: [String]? = nil,
        module: EditorModuleKind? = nil,
        moduleResolution: EditorModuleResolutionKind? = nil,
        typeRoots: [String]? = nil,
        strict: Bool? = nil
    ) {
        self.target = target
        self.lib = lib
        self.module = module
        self.moduleResolution = moduleResolution
        self.typeRoots = typeRoots
        self.strict = strict
    }

    public var isEmpty: Bool {
        target == nil
            && (lib?.isEmpty ?? true)
            && module == nil
            && moduleResolution == nil
            && (typeRoots?.isEmpty ?? true)
            && strict == nil
    }
}

/// Single TypeScript declaration file injected as ambient typings.
public struct EditorExtraLib: Sendable, Equatable, Codable {
    public var content: String
    public var filePath: String

    public init(content: String, filePath: String) {
        self.content = content
        self.filePath = filePath
    }
}

/// Editor profile shared across UI frontends. Each frontend translates
/// this into its concrete editor's configuration.
public struct EditorProfile: Sendable, Equatable, Codable {
    public var languageId: String
    public var theme: EditorTheme
    public var fontSize: Int
    public var minimap: Bool
    public var readOnly: Bool
    public var tsCompilerOptions: EditorCompilerOptions
    public var tsExtraLibs: [EditorExtraLib]
    public var jsCompilerOptions: EditorCompilerOptions
    public var jsExtraLibs: [EditorExtraLib]

    public init(
        languageId: String = "javascript",
        theme: EditorTheme = .dark,
        fontSize: Int = 14,
        minimap: Bool = false,
        readOnly: Bool = false,
        tsCompilerOptions: EditorCompilerOptions = .init(),
        tsExtraLibs: [EditorExtraLib] = [],
        jsCompilerOptions: EditorCompilerOptions = .init(),
        jsExtraLibs: [EditorExtraLib] = []
    ) {
        self.languageId = languageId
        self.theme = theme
        self.fontSize = fontSize
        self.minimap = minimap
        self.readOnly = readOnly
        self.tsCompilerOptions = tsCompilerOptions
        self.tsExtraLibs = tsExtraLibs
        self.jsCompilerOptions = jsCompilerOptions
        self.jsExtraLibs = jsExtraLibs
    }
}

// MARK: - Frida defaults and factory methods

extension EditorProfile {
    /// Compiler options Frida agents are written against (es2022 / node16 /
    /// strict). Used as both `tsCompilerOptions` and `jsCompilerOptions`.
    public static let fridaCompilerOptions = EditorCompilerOptions(
        target: .es2022,
        lib: ["es2022"],
        module: .node16,
        moduleResolution: .node16,
        strict: true
    )

    /// The bundled `frida-gum` declaration file as an extra lib, or nil
    /// if the resource could not be loaded.
    public static let fridaGumLib: EditorExtraLib? = {
        guard let typing = TypeScriptTypings.fridaGum else { return nil }
        return EditorExtraLib(content: typing.content, filePath: typing.filePath)
    }()

    /// Profile for the tracer hook editor: TypeScript with Frida defaults,
    /// the gum typings, the tracer-handler ambient declarations, and any
    /// global package alias typings.
    public static func fridaTracerHook(
        packages: [InstalledPackage],
        theme: EditorTheme = .dark,
        fontSize: Int = 13
    ) -> EditorProfile {
        var profile = EditorProfile(
            languageId: "typescript",
            theme: theme,
            fontSize: fontSize,
            tsCompilerOptions: fridaCompilerOptions
        )
        if let gum = fridaGumLib {
            profile.tsExtraLibs.append(gum)
        }
        profile.tsExtraLibs.append(TracerTypings.handlerLib)
        if let aliases = MonacoPackageAliasTypings.makeLib(packages: packages) {
            profile.tsExtraLibs.append(
                EditorExtraLib(content: aliases.content, filePath: aliases.filePath)
            )
        }
        return profile
    }

    /// Profile for the codeshare editor: JavaScript with Frida defaults
    /// and the gum typings.
    public static func fridaCodeShare(
        readOnly: Bool = false,
        theme: EditorTheme = .dark,
        fontSize: Int = 13
    ) -> EditorProfile {
        var profile = EditorProfile(
            languageId: "javascript",
            theme: theme,
            fontSize: fontSize,
            readOnly: readOnly,
            jsCompilerOptions: fridaCompilerOptions
        )
        if let gum = fridaGumLib {
            profile.jsExtraLibs.append(gum)
        }
        return profile
    }

    /// Profile for the custom-instrument editor: TypeScript with Frida
    /// defaults, the gum typings, the custom-instrument ambient
    /// declarations (so `Instrument`, `InstrumentContext`, etc. are in
    /// scope), and any global package alias typings.
    public static func fridaCustomInstrument(
        packages: [InstalledPackage],
        def: CustomInstrumentDef? = nil,
        theme: EditorTheme = .dark,
        fontSize: Int = 13
    ) -> EditorProfile {
        var profile = EditorProfile(
            languageId: "typescript",
            theme: theme,
            fontSize: fontSize,
            tsCompilerOptions: fridaCompilerOptions
        )
        if let gum = fridaGumLib {
            profile.tsExtraLibs.append(gum)
        }
        profile.tsExtraLibs.append(CustomInstrumentTypings.ambientLib)
        if let def, let featureMap = CustomInstrumentTypings.featureMapLib(for: def) {
            profile.tsExtraLibs.append(featureMap)
        }
        if let aliases = MonacoPackageAliasTypings.makeLib(packages: packages) {
            profile.tsExtraLibs.append(
                EditorExtraLib(content: aliases.content, filePath: aliases.filePath)
            )
        }
        return profile
    }
}

public enum CustomInstrumentTypings {
    public static let ambientDeclarations = #"""
        declare interface CustomInstrumentContext {
            emit(value: unknown): void;
            widget<K extends keyof CustomInstrumentWidgetMap>(id: K): CustomInstrumentWidgetMap[K];
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

        declare interface CustomInstrumentWidgetMap {
        }

        declare type CustomInstrumentAction = {
            [K in keyof CustomInstrumentWidgetMap]: CustomInstrumentWidgetMap[K] extends CustomInstrumentListWidget<infer A>
                ? { widget: K; action: A; item: string }
                : never
        }[keyof CustomInstrumentWidgetMap];

        declare type CustomFeatureValue = boolean | number | string | CustomFeatureValue[] | { [name: string]: CustomFeatureValue };

        declare interface CustomInstrumentFeatureMap {
        }

        declare interface CustomInstrumentConfig {
            features: CustomInstrumentFeatureMap;
        }

        declare interface CustomInstrumentHandle {
            updateConfig?(config: CustomInstrumentConfig): void | Promise<void>;
            onAction?(action: CustomInstrumentAction): void | Promise<void>;
            dispose?(): void | Promise<void>;
        }

        declare interface CustomInstrumentGraphSnapshot<Series extends string> {
            points: Array<{ series: Series; x: number; y: number }>;
        }

        declare interface CustomInstrumentListSnapshot {
            items: Array<{ id: string; title: string; subtitle?: string; accessory?: string }>;
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

    public static let ambientLib = EditorExtraLib(
        content: ambientDeclarations,
        filePath: "@types/frida-luma/custom-instrument.d.ts"
    )

    public static func featureMapLib(for def: CustomInstrumentDef) -> EditorExtraLib? {
        guard !def.features.isEmpty || !def.widgets.isEmpty else { return nil }
        return EditorExtraLib(
            content: defScopedDeclarations(for: def),
            filePath: "@types/frida-luma/custom-instrument-\(def.id.uuidString).d.ts"
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
        case .graph(let cfg):
            return "CustomInstrumentGraphWidget<\(stringLiteralUnion(cfg.series.map(\.id)))>"
        case .list(let cfg):
            return "CustomInstrumentListWidget<\(stringLiteralUnion(cfg.actions.map(\.id)))>"
        }
    }

    private static func snapshotType(for kind: InstrumentWidget.Kind) -> String {
        switch kind {
        case .graph(let cfg):
            return "CustomInstrumentGraphSnapshot<\(stringLiteralUnion(cfg.series.map(\.id)))>"
        case .list:
            return "CustomInstrumentListSnapshot"
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
        declare function defineHandler(h: Handler): void;

        type Handler = FunctionHandlers | InstructionHandler;

        interface FunctionHandlers {
            onEnter?: EnterHandler;
            onLeave?: LeaveHandler;
        }

        type EnterHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
        type LeaveHandler = (this: InvocationContext, log: LogHandler, retval: InvocationReturnValue) => any;
        type InstructionHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
        type LogHandler = (...args: any[]) => void;
        """#

    public static let handlerLib = EditorExtraLib(
        content: handlerDeclarations,
        filePath: "@types/frida-luma/tracer.d.ts"
    )
}
