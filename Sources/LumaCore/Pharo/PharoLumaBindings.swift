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
        | record records sessions entries events project synth tune |
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

        tune := Object << #LumaTune slots: { #tempo. #division. #root. #scale. #notes. #loops. #playing }; package: 'Luma'; install.
        tune compile: 'initialize
            tempo := 120.
            division := 4.
            root := 60.
            scale := #(0 3 5 7 10).
            notes := #().
            loops := true.
            playing := false'.
        tune compile: 'tempo ^ tempo'.
        tune compile: 'tempo: aTempo
            tempo := aTempo.
            self refresh'.
        tune compile: 'division: aDivision
            division := aDivision.
            self refresh'.
        tune compile: 'root: aMidiNote
            root := aMidiNote.
            self refresh'.
        tune compile: 'scale: aCollection
            scale := aCollection.
            self refresh'.
        tune compile: 'notes ^ notes'.
        tune compile: 'notes: aCollection
            notes := aCollection.
            self refresh'.
        tune compile: 'loops: aBoolean
            loops := aBoolean.
            self refresh'.
        tune compile: 'refresh
            playing ifTrue: [ self upload ]'.
        tune compile: 'play
            playing := true.
            LumaSynth start.
            self upload'.
        tune compile: 'stop
            playing := false.
            ^ LumaSynth invoke: ''luma_synth_pattern_stop'' parameters: #() return: TFBasicType void with: #()'.
        tune compile: 'upload
            | stepSeconds |
            LumaSynth invoke: ''luma_synth_pattern_begin'' parameters: #() return: TFBasicType void with: #().
            notes do: [ :each |
                LumaSynth invoke: ''luma_synth_pattern_add''
                    parameters: { TFBasicType float. TFBasicType float. TFBasicType sint }
                    return: TFBasicType void
                    with: { (self frequencyFor: each). 0.9. 1 } ].
            stepSeconds := 60.0 / tempo / division.
            ^ LumaSynth invoke: ''luma_synth_pattern_commit''
                parameters: { TFBasicType float. TFBasicType sint }
                return: TFBasicType void
                with: { stepSeconds asFloat. loops ifTrue: [ 1 ] ifFalse: [ 0 ] }'.
        tune compile: 'frequencyFor: aNote
            | midi |
            (aNote isNil or: [ aNote = #- ]) ifTrue: [ ^ 0.0 ].
            midi := aNote isInteger
                ifTrue: [ self midiForDegree: aNote ]
                ifFalse: [ self midiForName: aNote ].
            ^ (440.0 * (2 raisedTo: (midi - 69) / 12.0)) asFloat'.
        tune compile: 'midiForName: aSymbol
            | text octave step |
            text := aSymbol asString asLowercase.
            octave := (text select: [ :each | each isDigit ]) asNumber.
            step := #(c cs d ds e f fs g gs a as b)
                indexOf: (text select: [ :each | each isLetter ]) asSymbol.
            ^ ((octave + 1) * 12) + step - 1'.
        tune compile: 'midiForDegree: anInteger
            | octave index |
            octave := (anInteger / scale size) floor.
            index := anInteger - (octave * scale size).
            ^ root + (scale at: index + 1) + (octave * 12)'.
        tune class compile: 'tempo: aTempo
            ^ self new tempo: aTempo; yourself'.

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
        synth class compile: 'play: aFrequency velocity: aVelocity channel: aChannel
            ^ self invoke: ''luma_synth_play''
                parameters: { TFBasicType sint. TFBasicType float. TFBasicType float }
                return: TFBasicType sint
                with: { aChannel. aFrequency asFloat. aVelocity asFloat }'.
        synth class compile: 'release: aVoice
            ^ self invoke: ''luma_synth_release''
                parameters: { TFBasicType sint }
                return: TFBasicType void
                with: { aVoice }'.
        synth class compile: 'channel: aChannel waveform: aWaveform detune: aDetune attack: anAttack decay: aDecay sustain: aSustain release: aRelease cutoff: aCutoff resonance: aResonance gain: aGain
            ^ self invoke: ''luma_synth_set_patch''
                parameters: {
                    TFBasicType sint. TFBasicType sint. TFBasicType float.
                    TFBasicType float. TFBasicType float. TFBasicType float.
                    TFBasicType float. TFBasicType float. TFBasicType float. TFBasicType float }
                return: TFBasicType void
                with: {
                    aChannel. aWaveform. aDetune asFloat. anAttack asFloat.
                    aDecay asFloat. aSustain asFloat. aRelease asFloat.
                    aCutoff asFloat. aResonance asFloat. aGain asFloat }'.
        synth class compile: 'sine ^ 0'.
        synth class compile: 'triangle ^ 1'.
        synth class compile: 'saw ^ 2'.
        synth class compile: 'square ^ 3'.
        synth class compile: 'noise ^ 4'.
        synth class compile: 'pulse: aChannel
            ^ self channel: aChannel waveform: self square detune: 0 attack: 0.001
                decay: 0.09 sustain: 0 release: 0.01 cutoff: 0 resonance: 0 gain: 0.5'.
        synth class compile: 'bass: aChannel
            ^ self channel: aChannel waveform: self saw detune: 0.06 attack: 0.002
                decay: 0.22 sustain: 0 release: 0.03 cutoff: 900 resonance: 0.5 gain: 0.7'.
        synth class compile: 'noiseHit: aChannel
            ^ self channel: aChannel waveform: self noise detune: 0 attack: 0.001
                decay: 0.07 sustain: 0 release: 0.01 cutoff: 4200 resonance: 0.2 gain: 0.4'.
        synth class compile: 'blip: aChannel
            ^ self channel: aChannel waveform: self triangle detune: 0.08 attack: 0.004
                decay: 0.18 sustain: 0 release: 0.05 cutoff: 2600 resonance: 0.35 gain: 0.5'.

        tune := Object << #LumaTune
            slots: { #name. #channel. #tempo. #division. #root. #scale. #notes. #loops. #playing };
            sharedVariables: { #Registry };
            package: 'Luma';
            install.
        tune compile: 'initialize
            channel := 0.
            tempo := 120.
            division := 4.
            root := 60.
            scale := #(0 3 5 7 10).
            notes := #().
            loops := true.
            playing := false'.
        tune compile: 'name ^ name'.
        tune compile: 'setName: aSymbol
            name := aSymbol'.
        tune compile: 'printOn: aStream
            aStream nextPutAll: ''LumaTune''.
            name ifNotNil: [ aStream nextPut: $(; nextPutAll: name asString; nextPut: $) ]'.
        tune compile: 'channel ^ channel'.
        tune compile: 'channel: aChannel
            channel := aChannel.
            self refresh'.
        tune compile: 'tempo ^ tempo'.
        tune compile: 'tempo: aTempo
            tempo := aTempo.
            self refresh'.
        tune compile: 'division: aDivision
            division := aDivision.
            self refresh'.
        tune compile: 'root: aMidiNote
            root := aMidiNote.
            self refresh'.
        tune compile: 'scale: aCollection
            scale := aCollection.
            self refresh'.
        tune compile: 'notes ^ notes'.
        tune compile: 'notes: aCollection
            notes := aCollection.
            self refresh'.
        tune compile: 'loops: aBoolean
            loops := aBoolean.
            self refresh'.
        tune compile: 'patch: aSelector
            LumaSynth perform: (aSelector , '':'') asSymbol with: channel'.
        tune compile: 'refresh
            playing ifTrue: [ self upload ]'.
        tune compile: 'play
            playing := true.
            LumaSynth start.
            self upload'.
        tune compile: 'stop
            playing := false.
            ^ LumaSynth invoke: ''luma_synth_pattern_stop''
                parameters: { TFBasicType sint }
                return: TFBasicType void
                with: { channel }'.
        tune compile: 'upload
            | stepSeconds |
            LumaSynth invoke: ''luma_synth_pattern_begin''
                parameters: { TFBasicType sint } return: TFBasicType void with: { channel }.
            notes do: [ :each |
                | tones |
                tones := each isArray ifTrue: [ each ] ifFalse: [ Array with: each ].
                LumaSynth invoke: ''luma_synth_pattern_add''
                    parameters: { TFBasicType sint. TFBasicType float. TFBasicType float. TFBasicType sint }
                    return: TFBasicType void
                    with: { channel. (self frequencyFor: tones first). 0.9. 1 }.
                tones allButFirst do: [ :extra |
                    LumaSynth invoke: ''luma_synth_pattern_add_tone''
                        parameters: { TFBasicType sint. TFBasicType float }
                        return: TFBasicType void
                        with: { channel. (self frequencyFor: extra) } ] ].
            stepSeconds := 60.0 / tempo / division.
            ^ LumaSynth invoke: ''luma_synth_pattern_commit''
                parameters: { TFBasicType sint. TFBasicType float. TFBasicType sint }
                return: TFBasicType void
                with: { channel. stepSeconds asFloat. loops ifTrue: [ 1 ] ifFalse: [ 0 ] }'.
        tune compile: 'frequencyFor: aNote
            | midi |
            (aNote isNil or: [ aNote = #- ]) ifTrue: [ ^ 0.0 ].
            midi := aNote isInteger
                ifTrue: [ self midiForDegree: aNote ]
                ifFalse: [ self midiForName: aNote ].
            ^ (440.0 * (2 raisedTo: (midi - 69) / 12.0)) asFloat'.
        tune compile: 'midiForName: aSymbol
            | text octave step |
            text := aSymbol asString asLowercase.
            octave := (text select: [ :each | each isDigit ]) asNumber.
            step := #(c cs d ds e f fs g gs a as b)
                indexOf: (text select: [ :each | each isLetter ]) asSymbol.
            ^ ((octave + 1) * 12) + step - 1'.
        tune compile: 'midiForDegree: anInteger
            | octave index |
            octave := (anInteger / scale size) floor.
            index := anInteger - (octave * scale size).
            ^ root + (scale at: index + 1) + (octave * 12)'.
        tune class compile: 'registry
            Registry ifNil: [ Registry := Dictionary new ].
            ^ Registry'.
        tune class compile: 'named: aSymbol
            "A tune keeps its handle, so a later snippet reaches the one already playing."
            ^ self registry at: aSymbol ifAbsentPut: [ self new setName: aSymbol; yourself ]'.
        tune class compile: 'named: aSymbol channel: aChannel
            ^ (self named: aSymbol) channel: aChannel; yourself'.
        tune class compile: 'forget: aSymbol
            (self registry removeKey: aSymbol ifAbsent: [ nil ]) ifNotNil: [ :each | each stop ]'.
        tune class compile: 'channel: aChannel
            ^ self new channel: aChannel; yourself'.
        tune class compile: 'hush
            "Everything, registered or not."
            ^ self allInstances do: [ :each | each stop ]'.

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
        synth class compile: 'pulse
            ^ self
                waveform: self square detune: 0 attack: 0.001 decay: 0.09
                sustain: 0 release: 0.01 cutoff: 0 resonance: 0 gain: 0.5'.
        synth class compile: 'bass
            ^ self
                waveform: self saw detune: 0.06 attack: 0.002 decay: 0.22
                sustain: 0 release: 0.03 cutoff: 900 resonance: 0.5 gain: 0.7'.
        synth class compile: 'noiseHit
            ^ self
                waveform: self noise detune: 0 attack: 0.001 decay: 0.07
                sustain: 0 release: 0.01 cutoff: 4200 resonance: 0.2 gain: 0.4'.
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
