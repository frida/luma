enum PharoInstrumentBindings {
    static let source = """
        | environment failure refusal viewing code view context bytes input |
        environment := Object << #LumaInstrumentEnvironment slots: { #classes. #announcer }; package: 'Luma'; install.
        environment compile: 'initialize
            classes := IdentityDictionary new.
            announcer := SystemAnnouncer new'.
        environment compile: 'define: aClass
            aClass environment: self.
            classes at: aClass name put: (GlobalVariable key: aClass name value: aClass)'.
        environment compile: 'classNamed: aName
            ^ (classes at: aName asSymbol ifAbsent: [ ^ nil ]) value'.
        environment compile: 'bindingOf: aSymbol
            ^ classes at: aSymbol ifAbsent: [ Smalltalk globals bindingOf: aSymbol ]'.
        environment compile: 'lookupVar: aSymbol
            ^ classes at: aSymbol ifAbsent: [ Smalltalk globals lookupVar: aSymbol ]'.
        environment compile: 'at: aSymbol ifAbsent: aBlock
            ^ (classes at: aSymbol ifAbsent: [ ^ Smalltalk globals at: aSymbol ifAbsent: aBlock ]) value'.
        environment compile: 'associationAt: aSymbol ifAbsent: aBlock
            ^ classes at: aSymbol ifAbsent: [ Smalltalk globals associationAt: aSymbol ifAbsent: aBlock ]'.
        environment compile: 'organization
            ^ Smalltalk globals organization'.
        environment compile: 'codeChangeAnnouncer
            ^ announcer'.

        failure := Error << #LumaViewFailure slots: {}; package: 'Luma'; install.
        refusal := Exception << #LumaViewRefusal slots: {}; package: 'Luma'; install.
        refusal compile: 'isResumable
            ^ false'.
        refusal compile: 'defaultAction
            ^ UnhandledError signalForException: self'.
        viewing := ProcessLocalVariable << #LumaViewing slots: {}; package: 'Luma'; install.
        viewing compile: 'isInheritable ^ true'.

        code := Object << #LumaInstrumentCode slots: { #environment. #problems }; sharedVariables: { #Loaded }; package: 'Luma'; install.
        code class compile: 'load: aKey
            | loading |
            (self loaded includesKey: aKey) ifTrue: [ ^ self loaded at: aKey ].
            loading := self new.
            loading install: (LumaHost request: { #op -> ''view_code''. #code -> aKey } asDictionary).
            loading isSound ifTrue: [ self loaded at: aKey put: loading ].
            ^ loading'.
        code class compile: 'at: aKey
            ^ self loaded at: aKey ifAbsent: [ nil ]'.
        code class compile: 'forget: aKey
            self loaded removeKey: aKey ifAbsent: [ nil ]'.
        code class compile: 'loaded
            Loaded ifNil: [ Loaded := Dictionary new ].
            ^ Loaded'.
        code compile: 'initialize
            environment := LumaInstrumentEnvironment new.
            problems := OrderedCollection new'.
        code compile: 'install: aCollection
            | definitions |
            definitions := OrderedCollection new.
            aCollection do: [ :file |
                [ definitions addAll: ((TonelParser parseString: (file at: ''source'')) collect: [ :each | (file at: ''path'') -> each ]) ]
                    on: Error
                    do: [ :failure | self note: (file at: ''path''), '': '', failure messageText ] ].
            problems ifNotEmpty: [ ^ self ].
            self defineClasses: (definitions select: [ :each | each value isClassDefinition ]).
            problems ifNotEmpty: [ ^ self ].
            (definitions select: [ :each | each value isMethodDefinition ]) do: [ :each | self compile: each value in: each key ]'.
        code compile: 'defineClasses: aCollection
            | pending |
            pending := aCollection asOrderedCollection.
            [ pending isEmpty ] whileFalse: [
                | ready |
                ready := pending reject: [ :each | pending anySatisfy: [ :other | other value className = each value superclassName ] ].
                ready ifEmpty: [
                    ^ pending do: [ :each | self note: each key, '': '', each value className, '' inherits from itself'' ] ].
                ready do: [ :each | self define: each value in: each key ].
                pending removeAll: ready ]'.
        code compile: 'define: aDefinition in: aPath
            | superclass |
            (aDefinition class == MCClassDefinition and: [ aDefinition type = #normal ]) ifFalse: [
                ^ self note: aPath, '': only plain classes can be defined, and '', aDefinition className, '' is not one'' ].
            (environment classNamed: aDefinition className) ifNotNil: [
                ^ self note: aPath, '': '', aDefinition className, '' is defined twice'' ].
            superclass := (environment classNamed: aDefinition superclassName)
                ifNil: [ Smalltalk globals at: aDefinition superclassName asSymbol ifAbsent: [ nil ] ].
            (superclass notNil and: [ superclass isClass ]) ifFalse: [
                ^ self note: aPath, '': '', aDefinition className, '' inherits from '', aDefinition superclassName,
                    '', which is not a class'' ].
            [ environment define: (Smalltalk anonymousClassInstaller make: [ :builder |
                builder
                    name: aDefinition className asSymbol;
                    superclass: superclass;
                    slots: (aDefinition instVarNames collect: [ :each | each asSymbol ]) asArray;
                    sharedVariables: (aDefinition classVarNames collect: [ :each | each asSymbol ]) asArray;
                    classSlots: (aDefinition classInstVarNames collect: [ :each | each asSymbol ]) asArray ]) ]
                on: Error
                do: [ :failure | self note: aPath, '': '', aDefinition className, '': '', failure messageText ]'.
        code compile: 'compile: aDefinition in: aPath
            | target method |
            target := (environment classNamed: aDefinition className) ifNil: [
                ^ self note: aPath, '': '', aDefinition className, '' is not a class of this instrument, so it cannot be extended'' ].
            aDefinition classIsMeta ifTrue: [ target := target class ].
            [ method := target >> (target compile: aDefinition source classified: aDefinition protocol) ]
                on: Error
                do: [ :failure | ^ self note: aPath, '': '', target name, ''>>'', aDefinition selector, '': '', failure messageText ].
            (method literals select: [ :each | each isKindOf: UndeclaredVariable ]) do: [ :each |
                self note: aPath, '': '', target name, ''>>'', aDefinition selector, '' names '', each name, '', which nothing defines'' ]'.
        code compile: 'note: aString
            problems add: aString'.
        code compile: 'isSound
            ^ problems isEmpty'.
        code compile: 'printOn: aStream
            problems do: [ :each | aStream nextPutAll: each ] separatedBy: [ aStream cr ]'.
        code compile: 'classNamed: aName
            ^ environment classNamed: aName'.

        view := Object << #LumaInstrumentView slots: { #id. #object. #context }; package: 'Luma'; install.
        view class compile: 'open: anID
            ^ LumaRun on: anID do: [ self new setID: anID; listen; yourself ]'.
        view class compile: 'deadline
            ^ 3 seconds'.
        view class compile: 'refuseDeclaring: aSelector
            LumaViewing value ifNotNil: [
                LumaViewRefusal signal: ''declares an action button with '', aSelector, '', which a view cannot show'' ]'.
        view compile: 'setID: anID
            id := anID'.
        view compile: 'listen
            LumaSubscription
                subscribe: { #op -> ''view_inbox''. #view -> id } asDictionary
                do: [ :item |
                    LumaViewing value: self.
                    LumaRun on: id do: [ self handle: item ] ]'.
        view compile: 'handle: anItem
            | kind |
            kind := anItem at: ''kind''.
            kind = ''open'' ifTrue: [ ^ self guard: ''opening'' doing: [ self openWith: anItem ] ].
            kind = ''state'' ifTrue: [ ^ self deliver: #state:data: of: anItem ].
            kind = ''event'' ifTrue: [ ^ self deliver: #event:data: of: anItem ].
            kind = ''input'' ifTrue: [
                ^ object ifNotNil: [
                    self guard: ''input:'' doing: [ self tell: #input: with: (LumaInputEvent fromJSON: (anItem at: ''event'')) ] ] ].
            kind = ''views'' ifTrue: [ ^ self answer: anItem doing: [ self declarations ] ].
            kind = ''items'' ifTrue: [ ^ self answer: anItem doing: [ self itemsFor: anItem ] ].
            kind = ''send'' ifTrue: [ ^ self answer: anItem doing: [ self sentFor: anItem ] ].
            kind = ''close'' ifTrue: [ ^ self answer: anItem doing: [ self close. nil ] ]'.
        view compile: 'openWith: anItem
            | code made |
            code := (LumaInstrumentCode at: (anItem at: ''code'')) ifNil: [ ^ self fail: ''its Smalltalk is not loaded'' ].
            made := (code classNamed: (anItem at: ''class'')) ifNil: [
                ^ self fail: ''its Smalltalk defines no class '', (anItem at: ''class'') ].
            context := LumaViewContext new
                setView: self
                instance: (anItem at: ''instance'')
                widget: (anItem at: ''widget'')
                named: (anItem at: ''widgetName'').
            object := made new.
            self tell: #openIn: with: context'.
        view compile: 'deliver: aSelector of: anItem
            object ifNil: [ ^ self ].
            self guard: aSelector doing: [
                self tell: aSelector with: (anItem at: ''value'') with: (LumaBytes fromJSON: (anItem at: ''data'')) ]'.
        view compile: 'answer: anItem doing: aBlock
            | result |
            object ifNotNil: [ self guard: (anItem at: ''kind'') doing: [ result := aBlock value ] ].
            [ LumaHost request: ({ #op -> ''view_reply''. #view -> id. #request -> (anItem at: ''request'') },
                (object
                    ifNil: [ { #error -> ''the view stopped'' } ]
                    ifNotNil: [ { #result -> result } ])) asDictionary ]
                on: Error
                do: [ :failure | self fail: ''its answer could not be sent: '', failure description ]'.
        view compile: 'declarations
            ^ (self views collect: [ :each |
                self in: each methodSelector raising: [ each declaration ] ]) asArray'.
        view compile: 'views
            ^ (((SwpViewCollector gtViewSelectorsFor: object) collect: [ :each | self viewBy: each ])
                reject: [ :each | each isKindOf: SwpEmptyView ])
                asSortedCollection: #priority ascending , #methodSelector ascending'.
        view compile: 'viewBy: aSelector
            | view |
            view := self in: aSelector raising: [ SwpViewCollector viewOf: object bySending: aSelector ].
            (view isKindOf: SwpErrorView) ifTrue: [ LumaViewFailure signal: view text ].
            ^ view'.
        view compile: 'in: aSelector raising: aBlock
            ^ aBlock
                on: Error, LumaViewRefusal
                do: [ :failure | LumaViewFailure signal: aSelector, '' '', (self reasonFor: failure) ]'.
        view compile: 'itemsFor: anItem
            | shown |
            shown := self viewFor: anItem.
            ^ Dictionary new
                at: #total put: shown totalItems;
                at: #items put: (shown itemsFrom: (anItem at: ''from'') count: (anItem at: ''count'')) asArray;
                yourself'.
        view compile: 'viewFor: anItem
            | shown |
            shown := self views detect: [ :each | each methodSelector = (anItem at: ''view'') asSymbol ].
            (shown respondsTo: #filter:) ifTrue: [ shown filter: (anItem at: ''filter'' ifAbsent: [ nil ]) ].
            ^ shown'.
        view compile: 'sentFor: anItem
            | sent |
            sent := (self viewFor: anItem) sentItemAt: (anItem at: ''index'').
            ^ [ SwpBridge current session describe: sent ] valueUnpreemptively'.
        view compile: 'close
            self tell: #close'.
        view compile: 'adopt: aCanvas
            LumaRun adopt: aCanvas.
            LumaHost request: { #op -> ''view_canvas''. #view -> id. #scene -> aCanvas handle } asDictionary.
            ^ aCanvas'.
        view compile: 'guard: aWhat doing: aBlock
            [ [ aBlock
                valueWithin: self class deadline
                onTimeout: [ self fail: aWhat, '' did not finish within '', self class deadline asSeconds printString, '' seconds'' ] ]
                on: LumaViewFailure
                do: [ :failure | self fail: aWhat, '': '', failure messageText ] ]
                on: Error, Halt, LumaViewRefusal
                do: [ :failure | self fail: aWhat, '' '', (self reasonFor: failure) ]'.
        view compile: 'reasonFor: aFailure
            ^ (aFailure isKindOf: LumaViewRefusal)
                ifTrue: [ aFailure messageText ]
                ifFalse: [ ''raised '', aFailure description ]'.
        view compile: 'fail: aMessage
            object := nil.
            LumaHost request: { #op -> ''view_failed''. #view -> id. #message -> aMessage } asDictionary'.
        view compile: 'tell: aSelector with: anArgument
            (object respondsTo: aSelector) ifTrue: [ object perform: aSelector with: anArgument ]'.
        view compile: 'tell: aSelector with: anArgument with: anotherArgument
            (object respondsTo: aSelector) ifTrue: [ object perform: aSelector with: anArgument with: anotherArgument ]'.
        view compile: 'tell: aSelector
            (object respondsTo: aSelector) ifTrue: [ object perform: aSelector ]'.
        view compile: 'id
            ^ id'.

        context := Object << #LumaViewContext slots: { #view. #instance. #widget. #widgetName }; package: 'Luma'; install.
        context compile: 'setView: aView instance: anInstance widget: aWidget named: aName
            view := aView.
            instance := anInstance.
            widget := aWidget.
            widgetName := aName'.
        context compile: 'instanceID
            ^ instance'.
        context compile: 'widgetID
            ^ widget'.
        context compile: 'widgetName
            ^ widgetName'.
        context compile: 'canvas
            ^ view adopt: LumaCanvas new'.
        context compile: 'changed
            LumaHost request: { #op -> ''view_changed''. #view -> view id } asDictionary'.
        context compile: 'canSend
            ^ LumaHost request: { #op -> ''view_can_send''. #view -> view id } asDictionary'.
        context compile: 'send: aValue
            ^ self send: aValue data: nil'.
        context compile: 'send: aValue data: aByteArray
            | held |
            held := aByteArray ifNotNil: [ :data | LumaBytes holding: data ].
            ^ [ LumaHost request: {
                    #op -> ''view_send''.
                    #view -> view id.
                    #json -> (STONJSON toString: aValue).
                    #data -> (held ifNotNil: [ :bytes | bytes span ]) } asDictionary ]
                ensure: [ held ifNotNil: [ :bytes | bytes release ] ]'.
        context compile: 'fork: aBlock
            ^ LumaRun fork: [
                [ aBlock value ]
                    on: Error, Halt, LumaViewRefusal
                    do: [ :failure | view fail: ''a process it forked: '', failure description ] ]'.
        context compile: 'printOn: aStream
            aStream nextPutAll: ''LumaViewContext(''; nextPutAll: widgetName; nextPut: $)'.

        bytes := Object << #LumaBytes slots: { #blob. #offset. #size }; package: 'Luma'; install.
        bytes class compile: 'fromJSON: aDictionary
            aDictionary ifNil: [ ^ nil ].
            ^ self blob: (aDictionary at: ''blob'') offset: 0 size: (aDictionary at: ''size'')'.
        bytes class compile: 'blob: aBlob offset: anOffset size: aSize
            | made |
            made := self basicNew setBlob: aBlob offset: anOffset size: aSize; yourself.
            made toFinalizeSend: #releaseBlob: to: self with: aBlob.
            ^ made'.
        bytes class compile: 'holding: aByteArray
            | staged blob |
            staged := ExternalAddress allocate: (aByteArray size max: 1).
            [ LibC memCopy: aByteArray to: staged size: aByteArray size.
              blob := LumaHost invoke: ''luma_blob_create_copying''
                parameters: { TFBasicType pointer. TFBasicType sint64 } return: TFBasicType sint with: { staged. aByteArray size } ]
                ensure: [ staged free ].
            ^ self basicNew setBlob: blob offset: 0 size: aByteArray size; yourself'.
        bytes class compile: 'releaseBlob: aBlob
            LumaHost invoke: ''luma_blob_release''
                parameters: { TFBasicType sint } return: TFBasicType void with: { aBlob }'.
        bytes compile: 'setBlob: aBlob offset: anOffset size: aSize
            blob := aBlob.
            offset := anOffset.
            size := aSize'.
        bytes compile: 'size
            ^ size'.
        bytes compile: 'span
            ^ { blob. offset. size }'.
        bytes compile: 'printOn: aStream
            aStream nextPutAll: ''LumaBytes(''; print: size; nextPutAll: '' bytes)'''.
        bytes compile: 'from: anOffset size: aSize
            (anOffset >= 0 and: [ aSize >= 0 and: [ anOffset + aSize <= size ] ])
                ifFalse: [ ^ self errorSubscriptBounds: anOffset + aSize ].
            LumaHost invoke: ''luma_blob_retain'' parameters: { TFBasicType sint } return: TFBasicType void with: { blob }.
            ^ self class blob: blob offset: offset + anOffset size: aSize'.
        bytes compile: 'asByteArray
            | copy |
            copy := ByteArray new: size.
            self read: size at: 0 doing: [ :staged | LibC memCopy: staged to: copy size: size ].
            ^ copy'.
        bytes compile: 'float32At: anIndex
            (anIndex between: 1 and: size // 4) ifFalse: [ ^ self errorSubscriptBounds: anIndex ].
            ^ self read: 4 at: (anIndex - 1) * 4 doing: [ :staged | staged floatAt: 1 ]'.
        bytes compile: 'uint32At: anIndex
            (anIndex between: 1 and: size // 4) ifFalse: [ ^ self errorSubscriptBounds: anIndex ].
            ^ self read: 4 at: (anIndex - 1) * 4 doing: [ :staged | staged unsignedLongAt: 1 ]'.
        bytes compile: 'read: aCount at: anOffset doing: aBlock
            | staged |
            staged := ExternalAddress allocate: (aCount max: 1).
            ^ [ (LumaHost invoke: ''luma_blob_read''
                    parameters: { TFBasicType sint. TFBasicType sint64. TFBasicType sint64. TFBasicType pointer }
                    return: TFBasicType sint
                    with: { blob. offset + anOffset. aCount. staged }) = 1
                        ifFalse: [ self signalNotHeld ].
                aBlock value: staged ] ensure: [ staged free ]'.
        bytes compile: 'float32Extent: aCount
            | extent found |
            extent := FFIExternalArray externalNewType: ''float'' size: aCount * 2.
            ^ [ found := LumaHost invoke: ''luma_blob_float32_extent''
                    parameters: { TFBasicType sint. TFBasicType sint64. TFBasicType sint64. TFBasicType sint. TFBasicType pointer }
                    return: TFBasicType sint
                    with: { blob. offset. size. aCount. extent getHandle }.
                found < 0 ifTrue: [ self signalNotHeld ].
                found = 1
                    ifTrue: [ {
                        (1 to: aCount) collect: [ :each | extent at: each ].
                        (1 to: aCount) collect: [ :each | extent at: aCount + each ] } ]
                    ifFalse: [ nil ] ] ensure: [ extent free ]'.
        bytes compile: 'signalNotHeld
            LumaHostError signal: ''those bytes are not held any more'''.
        bytes compile: 'release
            blob = 0 ifTrue: [ ^ self ].
            self finalizationRegistry remove: self ifAbsent: [ nil ].
            self class releaseBlob: blob.
            blob := 0'.

        input := Object << #LumaInputEvent
            slots: { #kind. #x. #y. #buttons. #dx. #dy. #factor. #key. #width. #height };
            package: 'Luma';
            install.
        input class compile: 'fromJSON: aDictionary
            ^ self basicNew setFields: aDictionary; yourself'.
        input compile: 'setFields: aDictionary
            kind := (aDictionary at: ''kind'') asSymbol.
            x := aDictionary at: ''x''.
            y := aDictionary at: ''y''.
            buttons := aDictionary at: ''buttons''.
            dx := aDictionary at: ''dx''.
            dy := aDictionary at: ''dy''.
            factor := aDictionary at: ''factor''.
            key := aDictionary at: ''key''.
            width := aDictionary at: ''width''.
            height := aDictionary at: ''height'''.
        input compile: 'kind ^ kind'.
        input compile: 'x ^ x'.
        input compile: 'y ^ y'.
        input compile: 'position ^ x @ y'.
        input compile: 'buttons ^ buttons'.
        input compile: 'dx ^ dx'.
        input compile: 'dy ^ dy'.
        input compile: 'factor ^ factor'.
        input compile: 'key ^ key'.
        input compile: 'width ^ width'.
        input compile: 'height ^ height'.
        input compile: 'printOn: aStream
            aStream nextPutAll: ''LumaInputEvent(''; nextPutAll: kind; space; print: x; nextPut: $,; print: y; nextPut: $)'.

        LumaCanvas compile: 'stop
            ^ self destroy'.
        LumaDrawable compile: 'vertices: someBytes primitive: aSymbol
            ^ self vertices: someBytes indexSpan: #(-1 0 0) primitive: aSymbol'.
        LumaDrawable compile: 'vertices: someBytes indices: someIndices primitive: aSymbol
            ^ self vertices: someBytes indexSpan: someIndices span primitive: aSymbol'.
        LumaDrawable compile: 'vertices: someBytes indexSpan: anIndexSpan primitive: aSymbol
            ^ 1 = (LumaHost invoke: ''luma_drawable_set_vertex_bytes''
                parameters: {
                    TFBasicType sint. TFBasicType sint.
                    TFBasicType sint. TFBasicType sint64. TFBasicType sint64.
                    TFBasicType sint. TFBasicType sint64. TFBasicType sint64.
                    TFBasicType pointer }
                return: TFBasicType sint
                with: { scene. handle }, someBytes span, anIndexSpan, { aSymbol asString })'.

        (SwpView selectors select: [ :each | each beginsWith: 'action' ]) do: [ :each |
            SwpView
                compile: (String streamContents: [ :stream |
                    each numArgs = 0
                        ifTrue: [ stream nextPutAll: each ]
                        ifFalse: [ each keywords doWithIndex: [ :keyword :index |
                            stream nextPutAll: keyword; nextPutAll: ' argument'; print: index; space ] ].
                    stream cr; tab; nextPutAll: 'LumaInstrumentView refuseDeclaring: '; print: each ])
                classified: '*Luma' ].
        view
        """
}
