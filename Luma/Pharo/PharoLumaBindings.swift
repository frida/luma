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
    /// `callOut:` is where that lives so the exposed methods read as the
    /// questions they ask.
    private static let source = """
        | cls meta |
        cls := Object << #LumaProject slots: {}; package: 'Luma'; install.
        meta := cls class.
        meta compile: 'callOut: aName
            | address definition function |
            address := ExternalAddress loadSymbol: aName module: nil.
            definition := TFFunctionDefinition parameterTypes: #() returnType: TFBasicType sint32.
            function := TFExternalFunction fromAddress: address definition: definition.
            ^ TFSameThreadRunner uniqueInstance invokeFunction: function withArguments: #()'.
        meta compile: 'sessionCount
            ^ self callOut: ''luma_session_count'''.
        meta compile: 'notebookEntryCount
            ^ self callOut: ''luma_notebook_entry_count'''.
        meta compile: 'summary
            ^ Dictionary new
                at: #sessions put: self sessionCount;
                at: #notebookEntries put: self notebookEntryCount;
                yourself'.
        cls
        """
}
