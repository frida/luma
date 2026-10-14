enum PharoSessionBindings {
    static let source = """
        | session modules module functions function hook call pointer threads thread |
        session := LumaSession.
        session compile: 'id
            ^ self at: #id'.
        session compile: 'pointerSize
            ^ (self at: #pointerSize) asNumber'.
        session compile: 'pointer: anAddress
            ^ LumaPointer in: self at: anAddress'.
        session compile: 'request: anArrayOfAssociations
            | request |
            request := anArrayOfAssociations asDictionary.
            request at: #session put: self id.
            ^ LumaHost request: request'.
        session compile: 'modules
            ^ LumaModules new
                setItems: ((self request: { #op -> ''modules'' }) collect: [ :each | LumaModule fromJSON: each in: self ]);
                yourself'.
        session compile: 'moduleNamed: aName
            ^ self modules items detect: [ :each | each name = aName ]'.
        session compile: 'moduleAt: anAddress
            ^ self modules items detect: [ :each | each contains: anAddress ]'.
        session compile: 'threads
            ^ LumaThreads new
                setItems: ((self request: { #op -> ''threads'' }) collect: [ :each | LumaThread fromJSON: each in: self ]);
                yourself'.
        session compile: 'resolve: aQuery scope: aScope
            ^ LumaFunctions new
                setItems: ((self request: { #op -> ''resolve''. #scope -> aScope. #query -> aQuery })
                    collect: [ :each | LumaFunction fromJSON: each in: self ]);
                yourself'.
        session compile: 'functionsNamed: aName
            ^ self resolve: aName scope: ''function'''.
        session compile: 'functionNamed: aName
            ^ (self functionsNamed: aName) items first'.
        session compile: 'symbolicate: anAddress
            ^ (self request: { #op -> ''symbolicate''. #addresses -> { anAddress } }) first'.
        session compile: 'rangeAt: anAddress
            ^ self request: { #op -> ''range_at''. #address -> anAddress }'.
        session compile: 'read: aCount at: anAddress
            ^ (self request: { #op -> ''read_memory''. #address -> anAddress. #count -> aCount }) base64Decoded'.
        session compile: 'disassemble: aCount at: anAddress
            ^ self request: { #op -> ''disassemble''. #address -> anAddress. #count -> aCount }'.
        session compile: 'evaluate: aJavaScriptSource
            ^ self request: { #op -> ''evaluate_js''. #source -> aJavaScriptSource }'.
        session compile: 'events
            ^ LumaProject fetchEvents: { #op -> ''events''. #limit -> 200. #session -> self id }'.
        session compile: 'onEvent: aBlock
            ^ LumaProject watch: { #op -> ''watch_events''. #session -> self id } do: aBlock'.
        session compile: 'gtModulesFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Modules'';
                priority: 1;
                items: [ self modules items ];
                column: ''Name'' text: [ :each | each name ];
                column: ''Base'' text: [ :each | each baseString ];
                column: ''Size'' text: [ :each | each size printString ]'.
        session compile: 'gtThreadsFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Threads'';
                priority: 2;
                items: [ self threads items ];
                column: ''Id'' text: [ :each | each id printString ];
                column: ''Name'' text: [ :each | each name ifNil: [ '''' ] ]'.
        session compile: 'gtEventsFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Events'';
                priority: 3;
                items: [ self events items ];
                column: ''Time'' text: [ :each | each at: #timestamp ];
                column: ''Event'' text: [ :each | each name ]'.

        modules := LumaRecords << #LumaModules slots: {}; package: 'Luma'; install.
        modules compile: 'gtModulesFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Modules'';
                items: [ items ];
                column: ''Name'' text: [ :each | each name ];
                column: ''Base'' text: [ :each | each baseString ];
                column: ''Size'' text: [ :each | each size printString ]'.

        module := Object << #LumaModule slots: { #session. #name. #path. #base. #size }; package: 'Luma'; install.
        module class compile: 'fromJSON: aDictionary in: aSession
            ^ self new setSession: aSession json: aDictionary; yourself'.
        module compile: 'setSession: aSession json: aDictionary
            session := aSession.
            name := aDictionary at: ''name''.
            path := aDictionary at: ''path''.
            base := aDictionary at: ''base''.
            size := aDictionary at: ''size'''.
        module compile: 'session ^ session'.
        module compile: 'name ^ name'.
        module compile: 'path ^ path'.
        module compile: 'base ^ base'.
        module compile: 'size ^ size'.
        module compile: 'baseString
            ^ ''0x'' , (base printStringBase: 16) asLowercase'.
        module compile: 'contains: anAddress
            ^ anAddress between: base and: base + size - 1'.
        module compile: 'printOn: aStream
            aStream nextPutAll: name'.
        module compile: 'functions
            ^ LumaFunctions new
                setItems: ((session request: { #op -> ''module_functions''. #module -> name })
                    collect: [ :each | LumaFunction fromJSON: each in: session ]);
                yourself'.
        module compile: 'functionNamed: aName
            ^ self functions items detect: [ :each | each name = aName ]'.
        module compile: 'gtFunctionsFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Functions'';
                priority: 1;
                items: [ self functions items ];
                column: ''Address'' text: [ :each | each addressString ];
                column: ''Name'' text: [ :each | each name ];
                column: ''Source'' text: [ :each | each detail ]'.
        module compile: 'gtDetailsFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Details'';
                priority: 2;
                items: [ {
                    ''Name'' -> name.
                    ''Path'' -> path.
                    ''Base'' -> self baseString.
                    ''Size'' -> size printString } ];
                column: ''Field'' text: [ :each | each key ];
                column: ''Value'' text: [ :each | each value ]'.

        functions := LumaRecords << #LumaFunctions slots: {}; package: 'Luma'; install.
        functions compile: 'gtFunctionsFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Functions'';
                items: [ items ];
                column: ''Address'' text: [ :each | each addressString ];
                column: ''Name'' text: [ :each | each name ];
                column: ''Detail'' text: [ :each | each detail ]'.

        function := Object << #LumaFunction
            slots: { #session. #name. #address. #detail. #names. #arity. #captures };
            package: 'Luma';
            install.
        function class compile: 'fromJSON: aDictionary in: aSession
            ^ self new setSession: aSession json: aDictionary; yourself'.
        function compile: 'setSession: aSession json: aDictionary
            session := aSession.
            name := aDictionary at: ''name''.
            address := aDictionary at: ''address''.
            detail := aDictionary at: ''detail''.
            names := #().
            arity := 8.
            captures := Dictionary new'.
        function compile: 'session ^ session'.
        function compile: 'name ^ name'.
        function compile: 'address ^ address'.
        function compile: 'detail ^ detail'.
        function compile: 'arguments: aCollection
            names := aCollection collect: [ :each | each asString ].
            arity := names size'.
        function compile: 'names ^ names'.
        function compile: 'arity: aCount
            arity := aCount'.
        function compile: 'arity ^ arity'.
        function compile: 'capturing: aCollection
            captures := aCollection asDictionary'.
        function compile: 'captures ^ captures'.
        function compile: 'pointer
            ^ session pointer: address'.
        function compile: 'addressString
            ^ ''0x'' , (address printStringBase: 16) asLowercase'.
        function compile: 'printOn: aStream
            aStream nextPutAll: name; nextPutAll: '' @ ''; nextPutAll: self addressString'.
        function compile: 'module
            ^ session moduleAt: address'.
        function compile: 'disassembly
            ^ session disassemble: 64 at: address'.
        function compile: 'onCall: aBlock
            ^ LumaHook on: self at: #enter do: aBlock'.
        function compile: 'onReturn: aBlock
            ^ LumaHook on: self at: #leave do: aBlock'.
        function compile: 'gtDisassemblyFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Disassembly'';
                priority: 1;
                items: [ self disassembly ];
                column: ''Address'' text: [ :each | each at: ''address'' ];
                column: ''Bytes'' text: [ :each | each at: ''bytes'' ];
                column: ''Instruction'' text: [ :each | each at: ''asm'' ];
                column: ''Comment'' text: [ :each | each at: ''comment'' ]'.

        hook := LumaSubscription << #LumaHook
            slots: { #function. #tag. #cut };
            sharedVariables: { #Issued };
            package: 'Luma';
            install.
        hook class compile: 'on: aFunction at: aCut do: aBlock
            | tag watching |
            tag := self nextTag.
            watching := self
                subscribe: { #op -> ''watch_events''. #session -> aFunction session id. #hook -> tag } asDictionary
                do: [ :batch | batch do: [ :each |
                    aBlock value: (LumaCall on: aFunction json: ((LumaEvent fromJSON: each) message at: ''payload'')) ] ].
            watching setFunction: aFunction tag: tag cut: aCut.
            aFunction session evaluate: (self attachSourceFor: aFunction tag: tag at: aCut).
            ^ watching'.
        hook class compile: 'nextTag
            Issued := (Issued ifNil: [ 0 ]) + 1.
            ^ ''hook'' , Issued printString'.
        hook class compile: 'attachSourceFor: aFunction tag: aTag at: aCut
            | tag |
            tag := STONJSON toString: aTag.
            ^ String streamContents: [ :js |
                js nextPutAll: ''(globalThis.lumaHooks = globalThis.lumaHooks || {})['';
                    nextPutAll: tag;
                    nextPutAll: ''] = Interceptor.attach(ptr("'';
                    nextPutAll: aFunction addressString;
                    nextPutAll: ''"), { onEnter(args) { this.lumaArgs = '';
                    nextPutAll: (self argumentsSourceFor: aFunction);
                    nextPutAll: ''; this.lumaCaptured = '';
                    nextPutAll: (self capturesSourceFor: aFunction);
                    nextPutAll: ''; ''.
                aCut = #enter ifTrue: [ js nextPutAll: (self sendSourceFor: tag cut: aCut retval: ''null'') ].
                js nextPutAll: '' }''.
                aCut = #leave ifTrue: [
                    js nextPutAll: '', onLeave(retval) { '';
                        nextPutAll: (self sendSourceFor: tag cut: aCut retval: ''retval.toString()'');
                        nextPutAll: '' }'' ].
                js nextPutAll: '' });'' ]'.
        hook class compile: 'sendSourceFor: aTagLiteral cut: aCut retval: aRetvalSource
            ^ ''send({ hook: '' , aTagLiteral , '', cut: "'' , aCut , ''", thread: this.threadId, returnAddress: this.returnAddress.toString(), args: this.lumaArgs, captured: this.lumaCaptured, retval: '' , aRetvalSource , '' });'''.
        hook class compile: 'argumentsSourceFor: aFunction
            ^ String streamContents: [ :js |
                js nextPut: $[.
                1 to: aFunction arity do: [ :index |
                    index > 1 ifTrue: [ js nextPutAll: '', '' ].
                    js nextPutAll: ''args[''; print: index - 1; nextPutAll: ''].toString()'' ].
                js nextPut: $] ]'.
        hook class compile: 'capturesSourceFor: aFunction
            ^ String streamContents: [ :js |
                js nextPut: ${.
                aFunction captures keysAndValuesDo: [ :name :expression |
                    js nextPutAll: (STONJSON toString: name asString); nextPutAll: '': ''; nextPutAll: expression; nextPutAll: '', '' ].
                js nextPut: $} ]'.
        hook class compile: 'detachSourceFor: aTag
            ^ ''globalThis.lumaHooks["'' , aTag , ''"].detach(); delete globalThis.lumaHooks["'' , aTag , ''"];'''.
        hook compile: 'setFunction: aFunction tag: aTag cut: aCut
            function := aFunction.
            tag := aTag.
            cut := aCut'.
        hook compile: 'function ^ function'.
        hook compile: 'cut ^ cut'.
        hook compile: 'stop
            self isActive ifFalse: [ ^ self ].
            function session evaluate: (self class detachSourceFor: tag).
            super stop'.
        hook compile: 'printOn: aStream
            aStream nextPutAll: ''LumaHook(''; nextPutAll: function name; nextPutAll: '' ''; nextPutAll: cut; nextPut: $).
            self isActive ifFalse: [ aStream nextPutAll: '' stopped'' ].
            self error ifNotNil: [ :message | aStream nextPutAll: '': ''; nextPutAll: message ]'.

        call := Object << #LumaCall slots: { #function. #json }; package: 'Luma'; install.
        call class compile: 'on: aFunction json: aDictionary
            ^ self new setFunction: aFunction json: aDictionary; yourself'.
        call compile: 'setFunction: aFunction json: aDictionary
            function := aFunction.
            json := aDictionary'.
        call compile: 'function ^ function'.
        call compile: 'session ^ function session'.
        call compile: 'cut
            ^ (json at: ''cut'') asSymbol'.
        call compile: 'thread
            ^ json at: ''thread'''.
        call compile: 'returnAddress
            ^ function session pointer: (json at: ''returnAddress'')'.
        call compile: 'arguments
            ^ (json at: ''args'') collect: [ :each | function session pointer: each ]'.
        call compile: 'at: anIndex
            ^ function session pointer: ((json at: ''args'') at: anIndex)'.
        call compile: 'named: aName
            ^ self at: (function names indexOf: aName asString)'.
        call compile: 'captured
            ^ json at: ''captured'''.
        call compile: 'captured: aName
            ^ self captured at: aName asString'.
        call compile: 'retval
            ^ (json at: ''retval'') ifNotNil: [ :each | function session pointer: each ]'.
        call compile: 'nameOfArgument: anIndex
            ^ function names at: anIndex ifAbsent: [ anIndex printString ]'.
        call compile: 'printOn: aStream
            aStream nextPutAll: function name; nextPut: $(.
            self arguments doWithIndex: [ :each :index |
                index > 1 ifTrue: [ aStream nextPutAll: '', '' ].
                aStream print: each ].
            aStream nextPut: $).
            self retval ifNotNil: [ :result | aStream nextPutAll: '' -> ''; print: result ]'.
        call compile: 'gtArgumentsFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Arguments'';
                priority: 1;
                items: [ self arguments ];
                column: ''Name'' text: [ :each | self nameOfArgument: (self arguments indexOf: each) ];
                column: ''Value'' text: [ :each | each hex ]'.
        call compile: 'gtCapturedFor: aView
            <gtView>
            self captured isEmpty ifTrue: [ ^ aView ].
            ^ aView columnedList
                title: ''Captured'';
                priority: 2;
                items: [ self captured associations ];
                column: ''Name'' text: [ :each | each key ];
                column: ''Value'' text: [ :each | each value printString ]'.
        call compile: 'gtCallFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Call'';
                priority: 3;
                items: [ {
                    ''Function'' -> function printString.
                    ''Thread'' -> self thread printString.
                    ''Return address'' -> self returnAddress hex.
                    ''Returned'' -> (self retval ifNil: [ '''' ] ifNotNil: [ :result | result hex ]) } ];
                column: ''Field'' text: [ :each | each key ];
                column: ''Value'' text: [ :each | each value ]'.

        pointer := Object << #LumaPointer slots: { #session. #address }; package: 'Luma'; install.
        pointer class compile: 'in: aSession at: anAddressOrHex
            ^ self new setSession: aSession address: (self numberFrom: anAddressOrHex); yourself'.
        pointer class compile: 'numberFrom: anObject
            ^ anObject isString
                ifTrue: [ Integer readFrom: (anObject allButFirst: 2) base: 16 ]
                ifFalse: [ anObject ]'.
        pointer compile: 'setSession: aSession address: anAddress
            session := aSession.
            address := anAddress'.
        pointer compile: 'session ^ session'.
        pointer compile: 'address ^ address'.
        pointer compile: 'isNull
            ^ address = 0'.
        pointer compile: 'hex
            ^ ''0x'' , (address printStringBase: 16) asLowercase'.
        pointer compile: 'printOn: aStream
            aStream nextPutAll: self hex'.
        pointer compile: '= anObject
            ^ (anObject isKindOf: LumaPointer) and: [ anObject address = address ]'.
        pointer compile: 'hash
            ^ address hash'.
        pointer compile: '+ anOffset
            ^ LumaPointer in: session at: address + anOffset'.
        pointer compile: '- anOffset
            ^ LumaPointer in: session at: address - anOffset'.
        pointer compile: 'javaScript: aMessage
            ^ session evaluate: ''ptr("'' , self hex , ''").'' , aMessage'.
        pointer compile: 'readPointer
            ^ LumaPointer in: session at: (self javaScript: ''readPointer().toString()'')'.
        pointer compile: 'readU8 ^ self javaScript: ''readU8()'''.
        pointer compile: 'readU16 ^ self javaScript: ''readU16()'''.
        pointer compile: 'readU32 ^ self javaScript: ''readU32()'''.
        pointer compile: 'readU64 ^ self javaScript: ''readU64()'''.
        pointer compile: 'readS8 ^ self javaScript: ''readS8()'''.
        pointer compile: 'readS16 ^ self javaScript: ''readS16()'''.
        pointer compile: 'readS32 ^ self javaScript: ''readS32()'''.
        pointer compile: 'readS64 ^ self javaScript: ''readS64()'''.
        pointer compile: 'readFloat ^ self javaScript: ''readFloat()'''.
        pointer compile: 'readDouble ^ self javaScript: ''readDouble()'''.
        pointer compile: 'readUtf8String ^ self javaScript: ''readUtf8String()'''.
        pointer compile: 'readUtf8String: aLength
            ^ self javaScript: ''readUtf8String('' , aLength printString , '')'''.
        pointer compile: 'readUtf16String ^ self javaScript: ''readUtf16String()'''.
        pointer compile: 'readCString ^ self javaScript: ''readCString()'''.
        pointer compile: 'read: aCount
            ^ session read: aCount at: address'.
        pointer compile: 'decode: aTypeName using: aPattern
            ^ aPattern decode: aTypeName in: session at: address'.
        pointer compile: 'symbol
            ^ session symbolicate: address'.
        pointer compile: 'module
            ^ session moduleAt: address'.
        pointer compile: 'hexDump: aCount
            | bytes |
            bytes := self read: aCount.
            ^ String streamContents: [ :dump |
                0 to: aCount - 1 by: 16 do: [ :offset |
                    dump nextPutAll: (self + offset) hex; nextPutAll: ''  ''.
                    (bytes copyFrom: offset + 1 to: (offset + 16 min: aCount))
                        do: [ :byte | dump nextPutAll: (byte printStringBase: 16 length: 2 padded: true) asLowercase ]
                        separatedBy: [ dump space ].
                    dump lf ] ]'.
        pointer compile: 'gtSymbolFor: aView
            <gtView>
            | symbol |
            symbol := self symbol.
            symbol ifNil: [ ^ aView ].
            ^ aView columnedList
                title: ''Symbol'';
                priority: 1;
                items: [ symbol associations select: [ :each | each value notNil ] ];
                column: ''Field'' text: [ :each | each key ];
                column: ''Value'' text: [ :each | each value printString ]'.
        pointer compile: 'gtBytesFor: aView
            <gtView>
            ^ aView text
                title: ''Bytes'';
                priority: 2;
                text: [ self hexDump: 64 ]'.

        threads := LumaRecords << #LumaThreads slots: {}; package: 'Luma'; install.
        threads compile: 'gtThreadsFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Threads'';
                items: [ items ];
                column: ''Id'' text: [ :each | each id printString ];
                column: ''Name'' text: [ :each | each name ifNil: [ '''' ] ]'.

        thread := Object << #LumaThread slots: { #session. #id. #name. #entrypoint }; package: 'Luma'; install.
        thread class compile: 'fromJSON: aDictionary in: aSession
            ^ self new setSession: aSession json: aDictionary; yourself'.
        thread compile: 'setSession: aSession json: aDictionary
            session := aSession.
            id := aDictionary at: ''id''.
            name := aDictionary at: ''name''.
            entrypoint := aDictionary at: ''entrypoint'''.
        thread compile: 'session ^ session'.
        thread compile: 'id ^ id'.
        thread compile: 'name ^ name'.
        thread compile: 'entrypoint ^ entrypoint'.
        thread compile: 'printOn: aStream
            aStream nextPutAll: ''Thread ''; print: id.
            name ifNotNil: [ aStream space; nextPutAll: name ]'.
        thread compile: 'snapshot
            ^ session request: { #op -> ''thread_snapshot''. #thread -> id }'.
        thread compile: 'gtRegistersFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Registers'';
                priority: 1;
                items: [ self snapshot at: ''registers'' ];
                column: ''Register'' text: [ :each | each at: ''name'' ];
                column: ''Value'' text: [ :each | each at: ''value'' ]'.
        session
        """
}
