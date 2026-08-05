import SwiftyPharo

/// Teaches the image about the host it is running inside. The classes are
/// compiled on the way up rather than baked into the image, so what Luma
/// exposes stays in Luma.
public enum PharoLumaBindings {
    public static func install(into runtime: PharoRuntime) async throws {
        PharoSynthBridge.ensureExported()
        _ = try await runtime.evaluate(source)
    }

    /// Each feed is fetched only when it is asked for. A record carries its
    /// fields, so opening one shows what the host knows about it rather than
    /// the line it would have printed.
    private static let source = """
        | record records sessions entries events project synth |
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
            ^ icon ifNotNil: [ PNGReadWriter formFromStream: icon base64Decoded readStream ]'.
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
        synth := Object << #LumaSynth slots: {}; package: 'Luma'; install.
        synth class compile: 'invoke: aName parameters: aParameterTypes return: aReturnType with: aCollection
            | address definition function |
            address := ExternalAddress loadSymbol: aName module: nil.
            definition := TFFunctionDefinition parameterTypes: aParameterTypes returnType: aReturnType.
            function := TFExternalFunction fromAddress: address definition: definition.
            ^ TFSameThreadRunner uniqueInstance invokeFunction: function withArguments: aCollection'.
        synth class compile: 'start
            ^ self invoke: ''luma_synth_start'' parameters: #() return: TFBasicType sint with: #()'.
        synth class compile: 'stop
            ^ self invoke: ''luma_synth_stop'' parameters: #() return: TFBasicType void with: #()'.
        synth class compile: 'level: aLevel
            ^ self invoke: ''luma_synth_set_level''
                parameters: { TFBasicType float }
                return: TFBasicType void
                with: { aLevel asFloat }'.
        synth class compile: 'play: aFrequency velocity: aVelocity
            ^ self invoke: ''luma_synth_play''
                parameters: { TFBasicType float. TFBasicType float }
                return: TFBasicType sint
                with: { aFrequency asFloat. aVelocity asFloat }'.
        synth class compile: 'release: aVoice
            ^ self invoke: ''luma_synth_release''
                parameters: { TFBasicType sint }
                return: TFBasicType void
                with: { aVoice }'.
        synth class compile: 'waveform: aWaveform detune: aDetune attack: anAttack decay: aDecay sustain: aSustain release: aRelease cutoff: aCutoff resonance: aResonance gain: aGain
            ^ self invoke: ''luma_synth_set_patch''
                parameters: {
                    TFBasicType sint. TFBasicType float. TFBasicType float.
                    TFBasicType float. TFBasicType float. TFBasicType float.
                    TFBasicType float. TFBasicType float. TFBasicType float }
                return: TFBasicType void
                with: {
                    aWaveform. aDetune asFloat. anAttack asFloat.
                    aDecay asFloat. aSustain asFloat. aRelease asFloat.
                    aCutoff asFloat. aResonance asFloat. aGain asFloat }'.
        synth class compile: 'sine ^ 0'.
        synth class compile: 'triangle ^ 1'.
        synth class compile: 'saw ^ 2'.
        synth class compile: 'square ^ 3'.
        synth class compile: 'noise ^ 4'.
        synth class compile: 'blip
            ^ self
                waveform: self triangle detune: 0.08 attack: 0.004 decay: 0.18
                sustain: 0 release: 0.05 cutoff: 2600 resonance: 0.35 gain: 0.5'.

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
