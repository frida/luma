import LumaCore
import SwiftyPharo

/// Teaches the image about the host it is running inside. The classes are
/// compiled on the way up rather than baked into the image, so what Luma
/// exposes stays in Luma.
enum PharoLumaBindings {
    static func install(into runtime: PharoRuntime) async throws {
        _ = try await runtime.evaluate(source)
    }

    /// Reaching a host export takes a symbol lookup, a signature and a runner;
    /// `linesOf:` is where that lives, so each feed reads as the question it
    /// asks and is fetched only when it is asked for.
    private static let source = """
        | cls meta |
        cls := Object << #LumaProject slots: {}; package: 'Luma'; install.
        meta := cls class.
        meta compile: 'linesOf: aName
            | address definition function |
            address := ExternalAddress loadSymbol: aName module: nil.
            definition := TFFunctionDefinition parameterTypes: #() returnType: TFBasicType pointer.
            function := TFExternalFunction fromAddress: address definition: definition.
            ^ ((TFSameThreadRunner uniqueInstance invokeFunction: function withArguments: #())
                readString utf8Decoded) lines'.
        meta compile: 'sessions
            ^ self linesOf: ''luma_sessions'''.
        meta compile: 'notebookEntries
            ^ self linesOf: ''luma_notebook_entries'''.
        meta compile: 'events
            ^ self linesOf: ''luma_events'''.
        cls
        """
}
