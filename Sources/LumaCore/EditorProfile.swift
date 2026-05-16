import Foundation

/// Editor color theme identified by Monaco theme name. Use the bundled
/// static constants for built-in or first-party themes; pass a custom
/// name (with a matching `EditorCustomTheme` in the profile's
/// `customThemes`) to use third-party themes.
public struct EditorTheme: Sendable, Equatable, Codable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        self.name = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }

    public static let light = EditorTheme("vs")
    public static let dark = EditorTheme("vs-dark")
    public static let gitHubLight = EditorTheme("github-light")
    public static let gitHubDark = EditorTheme("github-dark")
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

/// A workspace-relative source file registered as a Monaco model so the
/// editor's TypeScript service can resolve cross-file imports without
/// requiring the file to live in the FS snapshot.
public struct EditorProjectFile: Sendable, Equatable, Hashable, Codable {
    public var path: String
    public var text: String
    public var languageId: String?

    public init(path: String, text: String, languageId: String? = nil) {
        self.path = path
        self.text = text
        self.languageId = languageId
    }
}

/// Editor profile shared across UI frontends. Each frontend translates
/// this into its concrete editor's configuration.
public struct EditorProfile: Sendable, Equatable, Codable {
    public var languageId: String
    public var projectFiles: [EditorProjectFile]
    public var activePath: String?
    public var theme: EditorTheme
    public var fontSize: Int
    public var minimap: Bool
    public var readOnly: Bool
    public var tsCompilerOptions: EditorCompilerOptions
    public var tsExtraLibs: [EditorExtraLib]
    public var jsCompilerOptions: EditorCompilerOptions
    public var jsExtraLibs: [EditorExtraLib]
    public var customThemes: [EditorCustomTheme]

    public init(
        languageId: String = "javascript",
        projectFiles: [EditorProjectFile] = [],
        activePath: String? = nil,
        theme: EditorTheme = .dark,
        fontSize: Int = 14,
        minimap: Bool = false,
        readOnly: Bool = false,
        tsCompilerOptions: EditorCompilerOptions = .init(),
        tsExtraLibs: [EditorExtraLib] = [],
        jsCompilerOptions: EditorCompilerOptions = .init(),
        jsExtraLibs: [EditorExtraLib] = [],
        customThemes: [EditorCustomTheme] = []
    ) {
        self.languageId = languageId
        self.projectFiles = projectFiles
        self.activePath = activePath
        self.theme = theme
        self.fontSize = fontSize
        self.minimap = minimap
        self.readOnly = readOnly
        self.tsCompilerOptions = tsCompilerOptions
        self.tsExtraLibs = tsExtraLibs
        self.jsCompilerOptions = jsCompilerOptions
        self.jsExtraLibs = jsExtraLibs
        self.customThemes = customThemes
    }
}

public struct EditorCustomTheme: Sendable, Equatable, Codable {
    public var name: String
    public var base: EditorBaseTheme
    public var inherit: Bool
    public var rules: [EditorTokenRule]
    public var colors: [String: String]

    public init(
        name: String,
        base: EditorBaseTheme,
        inherit: Bool = true,
        rules: [EditorTokenRule] = [],
        colors: [String: String] = [:]
    ) {
        self.name = name
        self.base = base
        self.inherit = inherit
        self.rules = rules
        self.colors = colors
    }
}

public enum EditorBaseTheme: String, Sendable, Equatable, Codable {
    case vs
    case vsDark = "vs-dark"
    case hcLight = "hc-light"
    case hcBlack = "hc-black"
}

public struct EditorTokenRule: Sendable, Equatable, Codable {
    public var token: String
    public var foreground: String?
    public var background: String?
    public var fontStyle: String?

    public init(token: String, foreground: String? = nil, background: String? = nil, fontStyle: String? = nil) {
        self.token = token
        self.foreground = foreground
        self.background = background
        self.fontStyle = fontStyle
    }
}

extension EditorCustomTheme {
    /// GitHub Light Default — palette mirrored from GitHub's VS Code theme.
    /// Editor chrome colors match exactly; syntax token coverage is
    /// approximate because Monaco's tokenizer is coarser than TextMate's.
    public static let gitHubLight = EditorCustomTheme(
        name: "github-light",
        base: .vs,
        rules: [
            EditorTokenRule(token: "", foreground: "1F2328", background: "FFFFFF"),
            EditorTokenRule(token: "comment", foreground: "59636E", fontStyle: "italic"),
            EditorTokenRule(token: "string", foreground: "0A3069"),
            EditorTokenRule(token: "string.escape", foreground: "0550AE"),
            EditorTokenRule(token: "regexp", foreground: "0A3069"),
            EditorTokenRule(token: "number", foreground: "0550AE"),
            EditorTokenRule(token: "number.hex", foreground: "0550AE"),
            EditorTokenRule(token: "number.float", foreground: "0550AE"),
            EditorTokenRule(token: "keyword", foreground: "CF222E"),
            EditorTokenRule(token: "keyword.flow", foreground: "CF222E"),
            EditorTokenRule(token: "keyword.json", foreground: "CF222E"),
            EditorTokenRule(token: "operator", foreground: "0550AE"),
            EditorTokenRule(token: "delimiter", foreground: "1F2328"),
            EditorTokenRule(token: "delimiter.bracket", foreground: "1F2328"),
            EditorTokenRule(token: "delimiter.parenthesis", foreground: "1F2328"),
            EditorTokenRule(token: "delimiter.square", foreground: "1F2328"),
            EditorTokenRule(token: "identifier", foreground: "1F2328"),
            EditorTokenRule(token: "type", foreground: "953800"),
            EditorTokenRule(token: "type.identifier", foreground: "953800"),
            EditorTokenRule(token: "class", foreground: "953800"),
            EditorTokenRule(token: "interface", foreground: "953800"),
            EditorTokenRule(token: "enum", foreground: "953800"),
            EditorTokenRule(token: "function", foreground: "8250DF"),
            EditorTokenRule(token: "predefined", foreground: "0550AE"),
            EditorTokenRule(token: "variable.predefined", foreground: "0550AE"),
            EditorTokenRule(token: "constant", foreground: "0550AE"),
            EditorTokenRule(token: "tag", foreground: "116329"),
            EditorTokenRule(token: "attribute.name", foreground: "0550AE"),
            EditorTokenRule(token: "attribute.value", foreground: "0A3069"),
            EditorTokenRule(token: "metatag", foreground: "116329"),
            EditorTokenRule(token: "metatag.content.html", foreground: "0A3069"),
            EditorTokenRule(token: "annotation", foreground: "953800"),
            EditorTokenRule(token: "namespace", foreground: "953800"),
            EditorTokenRule(token: "typeParameter", foreground: "953800"),
            EditorTokenRule(token: "parameter", foreground: "1F2328"),
            EditorTokenRule(token: "property", foreground: "0550AE"),
            EditorTokenRule(token: "variable", foreground: "1F2328"),
            EditorTokenRule(token: "variable.defaultLibrary", foreground: "0550AE"),
            EditorTokenRule(token: "enumMember", foreground: "0550AE"),
            EditorTokenRule(token: "member", foreground: "8250DF"),
            EditorTokenRule(token: "function.defaultLibrary", foreground: "8250DF"),
        ],
        colors: [
            "editor.background": "#FFFFFF",
            "editor.foreground": "#1F2328",
            "editorLineNumber.foreground": "#8C959F",
            "editorLineNumber.activeForeground": "#1F2328",
            "editorCursor.foreground": "#0969DA",
            "editor.selectionBackground": "#0969DA33",
            "editor.inactiveSelectionBackground": "#1F23281A",
            "editor.lineHighlightBackground": "#EAEEF280",
            "editor.lineHighlightBorder": "#00000000",
            "editorIndentGuide.background1": "#D0D7DE80",
            "editorIndentGuide.activeBackground1": "#8C959F",
            "editorWhitespace.foreground": "#AFB8C1",
            "editorBracketMatch.background": "#0969DA1F",
            "editorBracketMatch.border": "#0969DA80",
            "editorGutter.background": "#FFFFFF",
            "editorWidget.background": "#FFFFFF",
            "editorWidget.border": "#D0D7DE",
            "editorSuggestWidget.background": "#FFFFFF",
            "editorSuggestWidget.border": "#D0D7DE",
            "editorSuggestWidget.foreground": "#1F2328",
            "editorSuggestWidget.selectedBackground": "#0969DA1F",
            "editorHoverWidget.background": "#FFFFFF",
            "editorHoverWidget.border": "#D0D7DE",
            "scrollbar.shadow": "#1F232833",
            "scrollbarSlider.background": "#57606A80",
            "scrollbarSlider.hoverBackground": "#57606AB3",
            "scrollbarSlider.activeBackground": "#57606AE6",
        ]
    )

    /// GitHub Dark Default — palette mirrored from GitHub's VS Code theme.
    public static let gitHubDark = EditorCustomTheme(
        name: "github-dark",
        base: .vsDark,
        rules: [
            EditorTokenRule(token: "", foreground: "E6EDF3", background: "0D1117"),
            EditorTokenRule(token: "comment", foreground: "8B949E", fontStyle: "italic"),
            EditorTokenRule(token: "string", foreground: "A5D6FF"),
            EditorTokenRule(token: "string.escape", foreground: "79C0FF"),
            EditorTokenRule(token: "regexp", foreground: "A5D6FF"),
            EditorTokenRule(token: "number", foreground: "79C0FF"),
            EditorTokenRule(token: "number.hex", foreground: "79C0FF"),
            EditorTokenRule(token: "number.float", foreground: "79C0FF"),
            EditorTokenRule(token: "keyword", foreground: "FF7B72"),
            EditorTokenRule(token: "keyword.flow", foreground: "FF7B72"),
            EditorTokenRule(token: "keyword.json", foreground: "FF7B72"),
            EditorTokenRule(token: "operator", foreground: "79C0FF"),
            EditorTokenRule(token: "delimiter", foreground: "E6EDF3"),
            EditorTokenRule(token: "delimiter.bracket", foreground: "E6EDF3"),
            EditorTokenRule(token: "delimiter.parenthesis", foreground: "E6EDF3"),
            EditorTokenRule(token: "delimiter.square", foreground: "E6EDF3"),
            EditorTokenRule(token: "identifier", foreground: "E6EDF3"),
            EditorTokenRule(token: "type", foreground: "FFA657"),
            EditorTokenRule(token: "type.identifier", foreground: "FFA657"),
            EditorTokenRule(token: "class", foreground: "FFA657"),
            EditorTokenRule(token: "interface", foreground: "FFA657"),
            EditorTokenRule(token: "enum", foreground: "FFA657"),
            EditorTokenRule(token: "function", foreground: "D2A8FF"),
            EditorTokenRule(token: "predefined", foreground: "79C0FF"),
            EditorTokenRule(token: "variable.predefined", foreground: "79C0FF"),
            EditorTokenRule(token: "constant", foreground: "79C0FF"),
            EditorTokenRule(token: "tag", foreground: "7EE787"),
            EditorTokenRule(token: "attribute.name", foreground: "79C0FF"),
            EditorTokenRule(token: "attribute.value", foreground: "A5D6FF"),
            EditorTokenRule(token: "metatag", foreground: "7EE787"),
            EditorTokenRule(token: "metatag.content.html", foreground: "A5D6FF"),
            EditorTokenRule(token: "annotation", foreground: "FFA657"),
            EditorTokenRule(token: "namespace", foreground: "FFA657"),
            EditorTokenRule(token: "typeParameter", foreground: "FFA657"),
            EditorTokenRule(token: "parameter", foreground: "E6EDF3"),
            EditorTokenRule(token: "property", foreground: "79C0FF"),
            EditorTokenRule(token: "variable", foreground: "E6EDF3"),
            EditorTokenRule(token: "variable.defaultLibrary", foreground: "79C0FF"),
            EditorTokenRule(token: "enumMember", foreground: "79C0FF"),
            EditorTokenRule(token: "member", foreground: "D2A8FF"),
            EditorTokenRule(token: "function.defaultLibrary", foreground: "D2A8FF"),
        ],
        colors: [
            "editor.background": "#0D1117",
            "editor.foreground": "#E6EDF3",
            "editorLineNumber.foreground": "#6E7681",
            "editorLineNumber.activeForeground": "#E6EDF3",
            "editorCursor.foreground": "#58A6FF",
            "editor.selectionBackground": "#388BFD66",
            "editor.inactiveSelectionBackground": "#388BFD33",
            "editor.lineHighlightBackground": "#6E768133",
            "editor.lineHighlightBorder": "#00000000",
            "editorIndentGuide.background1": "#21262D",
            "editorIndentGuide.activeBackground1": "#6E7681",
            "editorWhitespace.foreground": "#484F58",
            "editorBracketMatch.background": "#3FB95040",
            "editorBracketMatch.border": "#3FB950",
            "editorGutter.background": "#0D1117",
            "editorWidget.background": "#161B22",
            "editorWidget.border": "#30363D",
            "editorSuggestWidget.background": "#161B22",
            "editorSuggestWidget.border": "#30363D",
            "editorSuggestWidget.foreground": "#E6EDF3",
            "editorSuggestWidget.selectedBackground": "#388BFD33",
            "editorHoverWidget.background": "#161B22",
            "editorHoverWidget.border": "#30363D",
            "scrollbarSlider.background": "#6E768140",
            "scrollbarSlider.hoverBackground": "#6E768166",
            "scrollbarSlider.activeBackground": "#6E768199",
        ]
    )
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

    public static let fridaGumLibs: [EditorExtraLib] = TypeScriptTypings.fridaGum.map {
        EditorExtraLib(content: $0.content, filePath: $0.filePath)
    }

    public static let nodeLibs: [EditorExtraLib] = TypeScriptTypings.node.map {
        EditorExtraLib(content: $0.content, filePath: $0.filePath)
    }

    /// Profile for the tracer hook editor: TypeScript with Frida defaults,
    /// the gum typings, the tracer-handler ambient declarations, and any
    /// global package alias typings.
    public static func fridaTracerHook(
        packages: [InstalledPackage],
        theme: EditorTheme = .gitHubDark,
        fontSize: Int = 13
    ) -> EditorProfile {
        var profile = EditorProfile(
            languageId: "typescript",
            theme: theme,
            fontSize: fontSize,
            tsCompilerOptions: fridaCompilerOptions,
            customThemes: [.gitHubLight, .gitHubDark]
        )
        profile.tsExtraLibs.append(contentsOf: fridaGumLibs)
        profile.tsExtraLibs.append(contentsOf: nodeLibs)
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
        theme: EditorTheme = .gitHubDark,
        fontSize: Int = 13
    ) -> EditorProfile {
        var profile = EditorProfile(
            languageId: "javascript",
            theme: theme,
            fontSize: fontSize,
            readOnly: readOnly,
            jsCompilerOptions: fridaCompilerOptions,
            customThemes: [.gitHubLight, .gitHubDark]
        )
        profile.jsExtraLibs.append(contentsOf: fridaGumLibs)
        profile.jsExtraLibs.append(contentsOf: nodeLibs)
        return profile
    }

    /// Profile for the custom-instrument editor: TypeScript with Frida
    /// defaults, the gum typings, the custom-instrument ambient
    /// declarations (so `Instrument`, `InstrumentContext`, etc. are in
    /// scope), and any global package alias typings.
    public static func fridaCustomInstrument(
        packages: [InstalledPackage],
        def: CustomInstrumentDef? = nil,
        files: [CustomInstrumentFile] = [],
        activePath: String? = nil,
        theme: EditorTheme = .gitHubDark,
        fontSize: Int = 13
    ) -> EditorProfile {
        var profile = EditorProfile(
            languageId: "typescript",
            projectFiles: files.map { file in
                EditorProjectFile(
                    path: CustomInstrumentFile.workspaceRelativePath(defID: file.defID, path: file.path),
                    text: file.content
                )
            },
            activePath: activePath,
            theme: theme,
            fontSize: fontSize,
            tsCompilerOptions: fridaCompilerOptions,
            customThemes: [.gitHubLight, .gitHubDark]
        )
        profile.tsExtraLibs.append(contentsOf: fridaGumLibs)
        profile.tsExtraLibs.append(contentsOf: nodeLibs)
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

        declare interface CustomInstrumentConsoleWidget {
            appendOutput(text: string): void;
            appendError(text: string): void;
            appendValue(value: unknown): void;
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
