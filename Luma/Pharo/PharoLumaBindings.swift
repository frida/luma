import LumaCore
import SwiftyPharo

/// Teaches the image about the host it is running inside. The classes are
/// compiled on the way up rather than baked into the image, so what Luma
/// exposes stays in Luma.
enum PharoLumaBindings {
    static func install(into runtime: PharoRuntime) async throws {
        _ = try await runtime.evaluate(source)
    }

    /// Each feed is fetched only when it is asked for. A record carries its
    /// fields, so opening one shows what the host knows about it rather than
    /// the line it would have printed.
    private static let source = """
        | record project |
        record := Object << #LumaRecord slots: { #fields }; package: 'Luma'; install.
        record compile: 'fields
            ^ fields'.
        record compile: 'setFields: aDictionary
            fields := aDictionary'.
        record compile: 'at: aKey
            ^ fields at: aKey asString ifAbsent: [ nil ]'.
        record compile: 'printOn: aStream
            aStream nextPutAll: (self at: #headline) asString'.
        record compile: 'inspectionFields: aBuilder
            <inspectorPresentationOrder: 0 title: ''Fields''>
            ^ aBuilder newTable
                addColumn: (SpStringTableColumn title: ''Field'' evaluated: [ :each | each key ]);
                addColumn: (SpStringTableColumn title: ''Value'' evaluated: [ :each | each value ]);
                items: fields associations;
                yourself'.
        record class compile: 'fromJSON: aDictionary
            | fields |
            fields := aDictionary at: ''fields''.
            fields at: ''headline'' put: (aDictionary at: ''headline'').
            ^ self new setFields: fields; yourself'.

        #(#LumaSession #LumaNotebookEntry #LumaEvent) do: [ :each |
            record << each slots: {}; package: 'Luma'; install ].

        project := Object << #LumaProject slots: {}; package: 'Luma'; install.
        project class compile: 'fetch: aName as: aClass
            | address definition function json |
            address := ExternalAddress loadSymbol: aName module: nil.
            definition := TFFunctionDefinition parameterTypes: #() returnType: TFBasicType pointer.
            function := TFExternalFunction fromAddress: address definition: definition.
            json := (TFSameThreadRunner uniqueInstance invokeFunction: function withArguments: #())
                readString utf8Decoded.
            ^ (STONJSON fromString: json) collect: [ :each | aClass fromJSON: each ]'.
        project class compile: 'sessions
            ^ self fetch: ''luma_sessions'' as: LumaSession'.
        project class compile: 'notebookEntries
            ^ self fetch: ''luma_notebook_entries'' as: LumaNotebookEntry'.
        project class compile: 'events
            ^ self fetch: ''luma_events'' as: LumaEvent'.
        project
        """
}
