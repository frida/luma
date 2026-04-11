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
