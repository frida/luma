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
        | record records sessions entries events project |
        record := Object << #LumaRecord slots: { #fields. #icon }; package: 'Luma'; install.
        record compile: 'setFields: aDictionary icon: anIcon
            fields := aDictionary.
            icon := anIcon'.
        record compile: 'at: aKey
            ^ fields at: aKey asString ifAbsent: [ nil ]'.
        record compile: 'name
            ^ (self at: #headline) asString'.
        record compile: 'printOn: aStream
            aStream nextPutAll: self name'.
        record compile: 'icon
            icon isString ifFalse: [ ^ icon ].
            icon := PNGReadWriter formFromStream: icon base64Decoded readStream.
            ^ icon'.
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
            ^ self new
                setFields: fields icon: (aDictionary at: ''icon'' ifAbsent: [ nil ]);
                yourself'.

        #(#LumaSession #LumaNotebookEntry #LumaEvent) do: [ :each |
            record << each slots: {}; package: 'Luma'; install ].

        records := Object << #LumaRecords slots: { #items }; package: 'Luma'; install.
        records compile: 'setItems: aCollection
            items := aCollection'.
        records compile: 'items
            ^ items'.

        sessions := records << #LumaSessions slots: {}; package: 'Luma'; install.
        sessions compile: 'gtSessionsFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Sessions'';
                items: [ items ];
                column: ''Icon'' icon: [ :each | each icon ];
                column: ''Name'' text: [ :each | each name ]'.

        entries := records << #LumaNotebookEntries slots: {}; package: 'Luma'; install.
        entries compile: 'gtEntriesFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Entries'';
                items: [ items ];
                column: ''Kind'' text: [ :each | each at: #kind ];
                column: ''Title'' text: [ :each | each name ]'.

        events := records << #LumaEvents slots: {}; package: 'Luma'; install.
        events compile: 'gtEventsFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Events'';
                items: [ items ];
                column: ''Time'' text: [ :each | each at: #timestamp ];
                column: ''Event'' text: [ :each | each name ]'.

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
            ^ LumaSessions new setItems: (self fetch: ''luma_sessions'' as: LumaSession); yourself'.
        project class compile: 'notebookEntries
            ^ LumaNotebookEntries new
                setItems: (self fetch: ''luma_notebook_entries'' as: LumaNotebookEntry);
                yourself'.
        project class compile: 'events
            ^ LumaEvents new
                setItems: (self fetch: ''luma_events'' as: LumaEvent);
                yourself'.
        project
        """
}
