enum PharoPatternBindings {
    static let source = """
        | decoding session pattern patterns value project |
        decoding := Object << #LumaDecoding slots: { #id }; package: 'Luma'; install.
        decoding class compile: 'id: anID
            | decoding |
            decoding := self new setID: anID; yourself.
            decoding toFinalizeSend: #release: to: self with: anID.
            ^ decoding'.
        decoding class compile: 'release: anID
            ^ LumaHost invoke: ''luma_pattern_release''
                parameters: { TFBasicType sint } return: TFBasicType void with: { anID }'.
        decoding compile: 'setID: anID
            id := anID'.
        decoding compile: 'id
            ^ id'.

        session := LumaSession.
        session compile: 'decode: aTypeName using: aPattern at: anAddress
            ^ aPattern decode: aTypeName in: self at: anAddress'.

        pattern := Object << #LumaPattern
            slots: { #id. #name. #kind. #types. #rootType. #diagnostics. #text };
            package: 'Luma';
            install.
        pattern class compile: 'fromJSON: aDictionary
            ^ self new setJSON: aDictionary; yourself'.
        pattern class compile: 'fromSource: aString
            ^ self new setText: aString; yourself'.
        pattern compile: 'setText: aString
            text := aString.
            name := ''untitled''.
            kind := ''source''.
            types := #().
            diagnostics := #()'.
        pattern compile: 'identity
            ^ text ifNil: [ { #pattern_id -> id } ] ifNotNil: [ { #source -> text } ]'.
        pattern compile: 'setJSON: aDictionary
            id := aDictionary at: ''id''.
            name := aDictionary at: ''name''.
            kind := aDictionary at: ''kind''.
            types := aDictionary at: ''types'' ifAbsent: [ #() ].
            rootType := aDictionary at: ''root_type'' ifAbsent: [ nil ].
            diagnostics := aDictionary at: ''diagnostics'' ifAbsent: [ #() ]'.
        pattern compile: 'id
            ^ id'.
        pattern compile: 'name
            ^ name'.
        pattern compile: 'types
            ^ types'.
        pattern compile: 'rootType
            ^ rootType'.
        pattern compile: 'diagnostics
            ^ diagnostics'.
        pattern compile: 'printOn: aStream
            aStream nextPutAll: name'.
        pattern compile: 'source
            ^ text ifNil: [ LumaHost request: { #op -> ''pattern_source''. #pattern_id -> id } asDictionary ]'.
        pattern compile: 'decode: aByteArray at: anAddress
            ^ self decode: rootType from: aByteArray at: anAddress'.
        pattern compile: 'decode: aTypeName from: aByteArray at: anAddress
            ^ LumaPatternValue
                fromReply: (LumaHost request: (self identity , {
                    #op -> ''decode''.
                    #type -> aTypeName.
                    #bytes -> aByteArray base64Encoded.
                    #address -> anAddress }) asDictionary)
                pattern: self
                session: nil'.
        pattern compile: 'decode: aTypeName in: aSession at: anAddress
            ^ LumaPatternValue
                fromReply: (LumaHost request: (self identity , {
                    #op -> ''decode''.
                    #type -> aTypeName.
                    #session -> (aSession at: #id).
                    #address -> anAddress }) asDictionary)
                pattern: self
                session: aSession'.
        pattern compile: 'decodeIn: aSession at: anAddress
            ^ self decode: rootType in: aSession at: anAddress'.
        pattern compile: 'gtTypesFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Types'';
                items: [ types ];
                column: ''Name'' text: [ :each | each at: ''name'' ];
                column: ''Kind'' text: [ :each | each at: ''kind'' ];
                column: ''Size'' text: [ :each | (each at: ''size'' ifAbsent: [ '''' ]) asString ]'.
        pattern compile: 'gtSourceFor: aView
            <gtView>
            ^ aView text
                title: ''Source'';
                text: [ self source ]'.
        pattern compile: 'gtDiagnosticsFor: aView
            <gtView>
            diagnostics isEmpty ifTrue: [ ^ aView ].
            ^ aView columnedList
                title: ''Diagnostics'';
                items: [ diagnostics ];
                column: ''Line'' text: [ :each | (each at: ''line'') asString ];
                column: ''Message'' text: [ :each | each at: ''message'' ]'.

        patterns := LumaRecords << #LumaPatterns slots: {}; package: 'Luma'; install.
        patterns compile: 'at: anID
            ^ items detect: [ :each | each id = anID ]'.
        patterns compile: 'gtPatternsFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Patterns'';
                items: [ items ];
                column: ''Name'' text: [ :each | each name ];
                column: ''Types'' text: [ :each | each types size asString ]'.

        value := Object << #LumaPatternValue
            slots: { #json. #children. #decoding. #pattern. #session };
            package: 'Luma';
            install.
        value class compile: 'fromReply: aDictionary pattern: aPattern session: aSession
            ^ self
                fromJSON: (aDictionary at: ''root'')
                in: (LumaDecoding id: (aDictionary at: ''decode''))
                pattern: aPattern
                session: aSession'.
        value class compile: 'fromJSON: aDictionary in: aDecoding pattern: aPattern session: aSession
            ^ self new setJSON: aDictionary in: aDecoding pattern: aPattern session: aSession; yourself'.
        value compile: 'setJSON: aDictionary in: aDecoding pattern: aPattern session: aSession
            json := aDictionary.
            decoding := aDecoding.
            pattern := aPattern.
            session := aSession.
            children := ((aDictionary at: ''fields'' ifAbsent: [ #() ]) , (aDictionary at: ''elements'' ifAbsent: [ #() ]))
                collect: [ :each | LumaPatternValue fromJSON: each in: aDecoding pattern: aPattern session: aSession ]'.
        value compile: 'pattern
            ^ pattern'.
        value compile: 'session
            ^ session'.
        value compile: 'name
            ^ json at: ''display_name'' ifAbsent: [ json at: ''name'' ifAbsent: [ '''' ] ]'.
        value compile: 'typeName
            ^ json at: ''type'''.
        value compile: 'address
            ^ Integer readFrom: ((json at: ''address'') allButFirst: 2) base: 16'.
        value compile: 'size
            ^ json at: ''size'' ifAbsent: [ nil ]'.
        value compile: 'value
            ^ json at: ''value'' ifAbsent: [ nil ]'.
        value compile: 'number
            ^ json at: ''number'''.
        value compile: 'isPointer
            ^ self typeName includes: $*'.
        value compile: 'pointeeTypeName
            ^ (self typeName copyUpTo: $*) trimBoth'.
        value compile: 'follow
            ^ self follow: self pointeeTypeName'.
        value compile: 'follow: aTypeName
            ^ pattern decode: aTypeName in: session at: self number'.
        value compile: 'pointer
            ^ session pointer: self number'.
        value compile: 'children
            ^ children'.
        value compile: 'at: aName
            ^ children detect: [ :each | each name = aName asString ]'.
        value compile: 'element: anIndex
            ^ children at: anIndex + 1'.
        value compile: 'reference
            ^ decoding id printString , '':'' , (json at: ''node'') printString'.
        value compile: 'printOn: aStream
            self name ifNotEmpty: [ :name | aStream nextPutAll: name; nextPutAll: '': '' ].
            aStream nextPutAll: self typeName.
            self value ifNotNil: [ :shown | aStream nextPutAll: '' = ''; nextPutAll: shown ]'.
        value compile: 'gtVisualizationFor: aView
            <gtView>
            (json includesKey: ''visualizer'') ifFalse: [ ^ aView ].
            ^ (LumaView new kindName: ''lumaPatternVisualization'')
                title: ''Visualization'';
                priority: 0;
                text: [ self reference ];
                yourself'.
        value compile: 'gtFieldsFor: aView
            <gtView>
            children isEmpty ifTrue: [ ^ aView ].
            ^ aView columnedList
                title: ''Fields'';
                priority: 1;
                items: [ children ];
                column: ''Name'' text: [ :each | each name ];
                column: ''Type'' text: [ :each | each typeName ];
                column: ''Value'' text: [ :each | each value ifNil: [ '''' ] ]'.
        value compile: 'gtPointeeFor: aView
            <gtView>
            (self isPointer and: [ children isEmpty ]) ifFalse: [ ^ aView ].
            ^ aView forward
                title: ''Pointee'';
                priority: 1;
                object: [ self follow ];
                view: #gtFieldsFor:'.
        value compile: 'gtBytesFor: aView
            <gtView>
            ^ (LumaView new kindName: ''lumaPatternBytes'')
                title: ''Bytes'';
                priority: 2;
                text: [ self reference ];
                yourself'.

        project := LumaProject.
        project class compile: 'patterns
            ^ LumaPatterns new
                setItems: ((LumaHost request: { #op -> ''patterns'' } asDictionary)
                    collect: [ :each | LumaPattern fromJSON: each ]);
                yourself'.
        project
        """
}
