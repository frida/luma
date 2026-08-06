import SwiftyPharo

/// Teaches the image about the host it is running inside. The classes are
/// compiled on the way up rather than baked into the image, so what Luma
/// exposes stays in Luma.
public enum PharoLumaBindings {
    public static func install(into runtime: PharoRuntime) async throws {
        PharoSynthBridge.ensureExported()
        PharoCanvasBridge.ensureExported()
        _ = try await runtime.evaluate(source)
    }

    /// Each feed is fetched only when it is asked for. A record carries its
    /// fields, so opening one shows what the host knows about it rather than
    /// the line it would have printed.
    private static let source = """
        | record records sessions entries events project host synth tune canvas drawable label |
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

        host := Object << #LumaHost slots: {}; package: 'Luma'; install.
        host class compile: 'invoke: aName parameters: aParameterTypes return: aReturnType with: aCollection
            "Calls one of the host''s luma_* entry points, which it resolves by
             name through dlsym."
            | address definition function |
            address := ExternalAddress loadSymbol: aName module: nil.
            definition := TFFunctionDefinition parameterTypes: aParameterTypes returnType: aReturnType.
            function := TFExternalFunction fromAddress: address definition: definition.
            ^ TFSameThreadRunner uniqueInstance invokeFunction: function withArguments: aCollection'.
        host class compile: 'invoke: aName
            ^ self invoke: aName parameters: #() return: TFBasicType void with: #()'.
        host class compile: 'cString: aString
            "The image reads strings out of the host readily but has no way to
             hand one in, so lay the bytes out in memory and pass the address."
            | bytes address |
            bytes := aString utf8Encoded.
            address := ExternalAddress allocate: bytes size + 1.
            1 to: bytes size do: [ :index |
                address unsignedByteAt: index put: (bytes at: index) ].
            address unsignedByteAt: bytes size + 1 put: 0.
            ^ address'.

        synth := Object << #LumaSynth slots: {}; package: 'Luma'; install.
        synth class compile: 'start
            ^ LumaHost invoke: ''luma_synth_start'' parameters: #() return: TFBasicType sint with: #()'.
        synth class compile: 'stop
            ^ LumaHost invoke: ''luma_synth_stop'''.
        synth class compile: 'level: aLevel
            ^ LumaHost invoke: ''luma_synth_set_level''
                parameters: { TFBasicType float }
                return: TFBasicType void
                with: { aLevel asFloat }'.
        synth class compile: 'play: aFrequency velocity: aVelocity channel: aChannel
            ^ LumaHost invoke: ''luma_synth_play''
                parameters: { TFBasicType sint. TFBasicType float. TFBasicType float }
                return: TFBasicType sint
                with: { aChannel. aFrequency asFloat. aVelocity asFloat }'.
        synth class compile: 'release: aVoice
            ^ LumaHost invoke: ''luma_synth_release''
                parameters: { TFBasicType sint }
                return: TFBasicType void
                with: { aVoice }'.
        synth class compile: 'channel: aChannel waveform: aWaveform detune: aDetune attack: anAttack decay: aDecay sustain: aSustain release: aRelease cutoff: aCutoff resonance: aResonance gain: aGain
            ^ LumaHost invoke: ''luma_synth_set_patch''
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
            ^ LumaHost invoke: ''luma_synth_pattern_stop''
                parameters: { TFBasicType sint }
                return: TFBasicType void
                with: { channel }'.
        tune compile: 'upload
            | stepSeconds |
            LumaHost invoke: ''luma_synth_pattern_begin''
                parameters: { TFBasicType sint } return: TFBasicType void with: { channel }.
            notes do: [ :each |
                | tones |
                tones := each isArray ifTrue: [ each ] ifFalse: [ Array with: each ].
                LumaHost invoke: ''luma_synth_pattern_add''
                    parameters: { TFBasicType sint. TFBasicType float. TFBasicType float. TFBasicType sint }
                    return: TFBasicType void
                    with: { channel. (self frequencyFor: tones first). 0.9. 1 }.
                tones allButFirst do: [ :extra |
                    LumaHost invoke: ''luma_synth_pattern_add_tone''
                        parameters: { TFBasicType sint. TFBasicType float }
                        return: TFBasicType void
                        with: { channel. (self frequencyFor: extra) } ] ].
            stepSeconds := 60.0 / tempo / division.
            ^ LumaHost invoke: ''luma_synth_pattern_commit''
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

        canvas := Object << #LumaCanvas slots: { #handle }; package: 'Luma'; install.
        canvas class compile: 'new
            "A scene of its own, which the image keeps and changes."
            ^ self basicNew
                setHandle: (LumaHost invoke: ''luma_scene_create''
                    parameters: #() return: TFBasicType sint with: #());
                yourself'.
        canvas compile: 'setHandle: aHandle
            handle := aHandle'.
        canvas compile: 'handle ^ handle'.
        canvas compile: 'printOn: aStream
            aStream nextPutAll: ''LumaCanvas(''; print: handle; nextPut: $)'.
        canvas compile: 'gtSceneFor: aView
            <gtView>
            ^ aView canvas title: ''Scene''; scene: [ handle ]'.
        canvas compile: 'addDrawable
            "One more thing for the scene to draw."
            ^ LumaDrawable new
                setScene: handle
                drawable: (LumaHost invoke: ''luma_scene_add_drawable''
                    parameters: { TFBasicType sint } return: TFBasicType sint with: { handle })'.
        canvas compile: 'remove: aDrawable
            ^ LumaHost invoke: ''luma_scene_remove_drawable''
                parameters: { TFBasicType sint. TFBasicType sint }
                return: TFBasicType void
                with: { handle. aDrawable handle }'.
        canvas compile: 'destroy
            ^ LumaHost invoke: ''luma_scene_destroy''
                parameters: { TFBasicType sint } return: TFBasicType void with: { handle }'.
        canvas compile: 'pointer
            "Where the pointer sits, in the clip space the vertices were
             given in: -1 to 1, y upwards."
            ^ Array
                with: (LumaHost invoke: ''luma_scene_pointer_x''
                    parameters: { TFBasicType sint } return: TFBasicType float with: { handle })
                with: (LumaHost invoke: ''luma_scene_pointer_y''
                    parameters: { TFBasicType sint } return: TFBasicType float with: { handle })'.
        canvas compile: 'buttons
            "Bit 0 primary, bit 1 secondary, bit 2 middle."
            ^ LumaHost invoke: ''luma_scene_buttons''
                parameters: { TFBasicType sint } return: TFBasicType sint with: { handle }'.
        canvas compile: 'isDown: aKey
            "A Character answers for itself; #left #right #up #down #space
             #enter and #escape are named."
            ^ 1 = (LumaHost invoke: ''luma_scene_key_down''
                parameters: { TFBasicType sint. TFBasicType sint }
                return: TFBasicType sint
                with: { handle. LumaCanvas keyCodes at: aKey ifAbsent: [ aKey asLowercase asInteger ] })'.
        canvas class compile: 'keyCodes
            ^ Dictionary newFrom: { #left -> 1. #right -> 2. #up -> 3. #down -> 4.
                                    #enter -> 13. #escape -> 27. #space -> 32 }'.
        canvas class compile: 'primitives
            ^ #(points lines lineStrip triangles triangleStrip)'.
        canvas class compile: 'lastError
            ^ (LumaHost invoke: ''luma_canvas_last_error''
                parameters: #() return: TFBasicType pointer with: #()) readString utf8Decoded'.

        drawable := Object << #LumaDrawable slots: { #scene. #handle }; package: 'Luma'; install.
        drawable compile: 'setScene: aScene drawable: aHandle
            scene := aScene.
            handle := aHandle'.
        drawable compile: 'handle ^ handle'.
        drawable compile: 'printOn: aStream
            aStream nextPutAll: ''LumaDrawable(''; print: handle; nextPut: $)'.
        drawable compile: 'clearLayout
            ^ LumaHost invoke: ''luma_drawable_clear_layout''
                parameters: { TFBasicType sint. TFBasicType sint }
                return: TFBasicType void
                with: { scene. handle }'.
        drawable compile: 'attribute: aName components: aCount
            "One value per vertex, in the author''s own layout."
            ^ LumaHost invoke: ''luma_drawable_add_attribute''
                parameters: { TFBasicType sint. TFBasicType sint. TFBasicType pointer.
                              TFBasicType sint. TFBasicType sint }
                return: TFBasicType void
                with: { scene. handle. (LumaHost cString: aName). aCount. 0 }'.
        drawable compile: 'varying: aName components: aCount
            "A value the vertex stage hands the fragment stage."
            ^ LumaHost invoke: ''luma_drawable_add_attribute''
                parameters: { TFBasicType sint. TFBasicType sint. TFBasicType pointer.
                              TFBasicType sint. TFBasicType sint }
                return: TFBasicType void
                with: { scene. handle. (LumaHost cString: aName). aCount. 1 }'.
        drawable compile: 'vertexSource: aVertexSource fragmentSource: aFragmentSource
            ^ LumaHost invoke: ''luma_drawable_set_source''
                parameters: { TFBasicType sint. TFBasicType sint.
                              TFBasicType pointer. TFBasicType pointer }
                return: TFBasicType void
                with: { scene. handle.
                        (LumaHost cString: aVertexSource). (LumaHost cString: aFragmentSource) }'.
        drawable compile: 'mesh: aCollection primitive: aSymbol
            "Hands over a whole buffer at once."
            | array |
            array := FFIExternalArray externalNewType: ''float'' size: aCollection size.
            aCollection doWithIndex: [ :value :index | array at: index put: value asFloat ].
            LumaHost invoke: ''luma_drawable_set_vertices''
                parameters: { TFBasicType sint. TFBasicType sint. TFBasicType pointer.
                              TFBasicType sint. TFBasicType sint }
                return: TFBasicType void
                with: { scene. handle. array getHandle. aCollection size.
                        (LumaCanvas primitives indexOf: aSymbol) - 1 }.
            array free.
            ^ self commit'.
        drawable compile: 'remesh: aCollection primitive: aSymbol
            "Fresh vertices for stages that are already built, which is what
             makes changing text cost a buffer rather than a compile."
            | array |
            array := FFIExternalArray externalNewType: ''float'' size: aCollection size.
            aCollection doWithIndex: [ :value :index | array at: index put: value asFloat ].
            LumaHost invoke: ''luma_drawable_set_vertices''
                parameters: { TFBasicType sint. TFBasicType sint. TFBasicType pointer.
                              TFBasicType sint. TFBasicType sint }
                return: TFBasicType void
                with: { scene. handle. array getHandle. aCollection size.
                        (LumaCanvas primitives indexOf: aSymbol) - 1 }.
            array free'.
        drawable compile: 'uniform: aName value: aValue
            "A uniform of the author''s own naming. A number or a collection
             of up to sixteen; the host declares it and packs it to match."
            | values array |
            values := aValue isCollection ifTrue: [ aValue ] ifFalse: [ Array with: aValue ].
            array := FFIExternalArray externalNewType: ''float'' size: values size.
            values doWithIndex: [ :each :index | array at: index put: each asFloat ].
            LumaHost invoke: ''luma_drawable_set_uniform''
                parameters: { TFBasicType sint. TFBasicType sint. TFBasicType pointer.
                              TFBasicType pointer. TFBasicType sint }
                return: TFBasicType void
                with: { scene. handle. (LumaHost cString: aName). array getHandle. values size }.
            array free'.
        drawable compile: 'drive: aName kind: aKind from: aFrom to: aTo seconds: aSeconds
            "Says what a value should do; the renderers work it out on their
             own clock, so nothing here runs per frame."
            | from to source target |
            from := aFrom isCollection ifTrue: [ aFrom ] ifFalse: [ Array with: aFrom ].
            to := aTo isCollection ifTrue: [ aTo ] ifFalse: [ Array with: aTo ].
            source := FFIExternalArray externalNewType: ''float'' size: from size.
            target := FFIExternalArray externalNewType: ''float'' size: to size.
            from doWithIndex: [ :each :index | source at: index put: each asFloat ].
            to doWithIndex: [ :each :index | target at: index put: each asFloat ].
            LumaHost invoke: ''luma_drawable_drive_uniform''
                parameters: { TFBasicType sint. TFBasicType sint. TFBasicType pointer.
                              TFBasicType sint. TFBasicType pointer. TFBasicType pointer.
                              TFBasicType sint. TFBasicType float }
                return: TFBasicType void
                with: { scene. handle. (LumaHost cString: aName). aKind.
                        source getHandle. target getHandle. from size. aSeconds asFloat }.
            source free.
            target free'.
        drawable compile: 'buffer: aName values: aCollection
            "A run of values the shader reads by index through <name>At(i).
             Held as a texture, so it can be far larger than a uniform, and
             handing over a fresh window is all a scrub costs."
            | array |
            array := FFIExternalArray externalNewType: ''float'' size: aCollection size.
            aCollection doWithIndex: [ :each :index | array at: index put: each asFloat ].
            LumaHost invoke: ''luma_drawable_set_buffer''
                parameters: { TFBasicType sint. TFBasicType sint. TFBasicType pointer.
                              TFBasicType pointer. TFBasicType sint }
                return: TFBasicType void
                with: { scene. handle. (LumaHost cString: aName).
                        array getHandle. aCollection size }.
            array free'.
        drawable compile: 'image: aName form: aForm
            "A picture the shader samples across, said as texture(<name>, uv).
             Any Form will do -- a session icon, something the image drew."
            | picture bits array |
            picture := aForm asFormOfDepth: 32.
            bits := picture bits.
            array := FFIExternalArray externalNewType: ''uint'' size: bits size.
            1 to: bits size do: [ :index | array at: index put: (bits at: index) ].
            LumaHost invoke: ''luma_drawable_set_image''
                parameters: { TFBasicType sint. TFBasicType sint. TFBasicType pointer.
                              TFBasicType pointer. TFBasicType sint. TFBasicType sint }
                return: TFBasicType void
                with: { scene. handle. (LumaHost cString: aName).
                        array getHandle. picture width. picture height }.
            array free'.
        drawable compile: 'ramp: aName from: aFrom to: aTo over: aSeconds
            "Moves once, and stays where it lands."
            ^ self drive: aName kind: 0 from: aFrom to: aTo seconds: aSeconds'.
        drawable compile: 'oscillate: aName between: aLow and: aHigh period: aPeriod
            "Swings back and forth, for as long as it is drawn."
            ^ self drive: aName kind: 1 from: aLow to: aHigh seconds: aPeriod'.
        drawable compile: 'commit
            "Wraps the stages in declarations matching the layout, and answers
             false leaving lastError set when either will not compile."
            ^ 1 = (LumaHost invoke: ''luma_drawable_commit''
                parameters: { TFBasicType sint. TFBasicType sint }
                return: TFBasicType sint
                with: { scene. handle })'.
        drawable compile: 'transform: aCollection
            | array |
            array := FFIExternalArray externalNewType: ''float'' size: 16.
            aCollection doWithIndex: [ :value :index | array at: index put: value asFloat ].
            LumaHost invoke: ''luma_drawable_set_transform''
                parameters: { TFBasicType sint. TFBasicType sint. TFBasicType pointer }
                return: TFBasicType void
                with: { scene. handle. array getHandle }.
            array free'.
        drawable compile: 'identity
            ^ self transform: #(1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1)'.
        drawable compile: 'orthographicWidth: aWidth height: aHeight
            ^ self transform: {
                2.0 / aWidth. 0. 0. 0.
                0. 2.0 / aHeight. 0. 0.
                0. 0. -1.0. 0.
                0. 0. 0. 1.0 }'.
        drawable compile: 'perspective: aFieldOfView aspect: anAspect near: aNear far: aFar
            | focal range |
            focal := 1.0 / (aFieldOfView / 2.0) degreesToRadians tan.
            range := aNear - aFar.
            ^ self transform: {
                focal / anAspect. 0. 0. 0.
                0. focal. 0. 0.
                0. 0. (aFar + aNear) / range. -1.0.
                0. 0. 2.0 * aFar * aNear / range. 0 }'.
        drawable compile: 'hide
            ^ LumaHost invoke: ''luma_drawable_set_visible''
                parameters: { TFBasicType sint. TFBasicType sint. TFBasicType sint }
                return: TFBasicType void
                with: { scene. handle. 0 }'.
        drawable compile: 'show
            ^ LumaHost invoke: ''luma_drawable_set_visible''
                parameters: { TFBasicType sint. TFBasicType sint. TFBasicType sint }
                return: TFBasicType void
                with: { scene. handle. 1 }'.

        label := Object << #LumaText slots: { #drawable. #font. #cell. #columns }; package: 'Luma'; install.
        label class compile: 'on: aDrawable
            ^ self on: aDrawable pointSize: 22'.
        label class compile: 'on: aDrawable pointSize: aSize
            "Lettering for a scene. The glyphs are drawn once into an atlas the
             shader samples, so saying something else costs a buffer of
             corners rather than a rasterisation.

             The point size is in the same units as the rest of the interface,
             whatever a display packs into one of them, and the atlas is
             rasterised to match rather than the quads being scaled -- which
             is what would make the lettering soft."
            ^ self basicNew
                setDrawable: aDrawable pointSize: aSize;
                buildAtlas;
                buildStages;
                yourself'.
        label compile: 'setDrawable: aDrawable pointSize: aSize
            drawable := aDrawable.
            "Rasterised at twice the asked-for size, so a display with two
             physical pixels to a logical one draws it texel for texel and
             an ordinary one halves it, which is kinder than magnifying."
            font := LogicalFont familyName: ''Source Code Pro'' pointSize: aSize * 2.
            columns := 16'.
        label compile: 'first ^ 32'.
        label compile: 'last ^ 126'.
        label compile: 'buildAtlas
            | rows atlas canvas |
            cell := (self widest + 2) @ (font height + 2).
            rows := (self last - self first + 1 + columns - 1) // columns.
            atlas := Form extent: (cell x * columns) @ (cell y * rows) depth: 32.
            canvas := atlas getCanvas.
            self first to: self last do: [ :code |
                | at |
                at := self cellOrigin: code.
                canvas
                    drawString: (String with: (Character value: code))
                    at: at + (1 @ 1)
                    font: font
                    color: Color white ].
            drawable image: ''glyphs'' form: atlas'.
        label compile: 'widest
            ^ (self first to: self last) inject: 1 into: [ :widest :code |
                widest max: (font widthOf: (Character value: code)) ]'.
        label compile: 'cellOrigin: aCode
            | index |
            index := aCode - self first.
            ^ (index \\\\ columns * cell x) @ (index // columns * cell y)'.
        label compile: 'buildStages
            drawable
                attribute: ''p'' components: 2;
                attribute: ''glyph'' components: 2;
                varying: ''uv'' components: 2;
                uniform: ''pad'' value: #(16 16);
                uniform: ''size'' value: font height / 2;
                uniform: ''tint'' value: #(1 1 1);
                vertexSource: ''void main() {
                    uv = glyph;
                    vec2 pixel = 2.0 * u_scale / u_resolution;
                    vec2 origin = vec2(-1.0, 1.0) + vec2(pad.x, -pad.y) * pixel;
                    gl_Position = vec4(origin + p * size * pixel, 0.15, 1.0); }''
                fragmentSource: ''void main() {
                    float ink = texture(glyphs, uv).a;
                    if (ink < 0.02) discard;
                    frag_color = vec4(tint * ink, ink); }'';
                mesh: #() primitive: #triangles'.
        label compile: 'pad: aPoint tint: aColour
            "Pixels from the top-left corner, both axes alike, so the gap
             above the lettering is the gap beside it whatever shape the
             view happens to be."
            ^ drawable
                uniform: ''pad'' value: aPoint;
                uniform: ''tint'' value: aColour'.
        label compile: 'show: aString
            "Two triangles a letter, laid out along the baseline in ems."
            | corners pen atlas |
            corners := OrderedCollection new.
            pen := 0.0.
            atlas := cell x * columns @ (cell y * ((self last - self first + 1 + columns - 1) // columns)).
            aString do: [ :each |
                | code advance origin wide high |
                code := each asInteger.
                (code between: self first and: self last)
                    ifTrue: [
                        advance := (font widthOf: each) / font height.
                        origin := self cellOrigin: code.
                        wide := cell x / font height.
                        high := cell y / font height.
                        #(#(0 0) #(1 0) #(0 1) #(1 0) #(1 1) #(0 1)) do: [ :corner |
                            | cx cy |
                            cx := (corner at: 1). cy := (corner at: 2).
                            corners
                                add: pen + (cx * wide); add: (cy - 1) * high;
                                add: (origin x + (cx * cell x)) / atlas x;
                                add: (origin y + ((1 - cy) * cell y)) / atlas y ].
                        pen := pen + advance ]
                    ifFalse: [ pen := pen + 0.5 ] ].
            ^ drawable remesh: corners primitive: #triangles'.
        label compile: 'drawable ^ drawable'.

        project := Object << #LumaProject slots: {}; package: 'Luma'; install.
        project class compile: 'fetch: aName as: aClass
            | json |
            json := (LumaHost invoke: aName
                parameters: #() return: TFBasicType pointer with: #()) readString utf8Decoded.
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
