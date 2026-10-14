enum PharoSessionBindings {
    static let source = """
        | session modules module functions function hook threads thread |
        session := LumaSession.
        session compile: 'id
            ^ self at: #id'.
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

        function := Object << #LumaFunction slots: { #session. #name. #address. #detail }; package: 'Luma'; install.
        function class compile: 'fromJSON: aDictionary in: aSession
            ^ self new setSession: aSession json: aDictionary; yourself'.
        function compile: 'setSession: aSession json: aDictionary
            session := aSession.
            name := aDictionary at: ''name''.
            address := aDictionary at: ''address''.
            detail := aDictionary at: ''detail'''.
        function compile: 'session ^ session'.
        function compile: 'name ^ name'.
        function compile: 'address ^ address'.
        function compile: 'detail ^ detail'.
        function compile: 'addressString
            ^ ''0x'' , (address printStringBase: 16) asLowercase'.
        function compile: 'printOn: aStream
            aStream nextPutAll: name; nextPutAll: '' @ ''; nextPutAll: self addressString'.
        function compile: 'module
            ^ session moduleAt: address'.
        function compile: 'disassembly
            ^ session disassemble: 64 at: address'.
        function compile: 'onCall: aBlock
            ^ LumaHook on: self do: aBlock'.
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
            slots: { #function. #tag };
            sharedVariables: { #Issued };
            package: 'Luma';
            install.
        hook class compile: 'on: aFunction do: aBlock
            | tag watching |
            tag := self nextTag.
            watching := self
                subscribe: { #op -> ''watch_events''. #session -> aFunction session id. #hook -> tag } asDictionary
                do: [ :each | aBlock value: ((LumaEvent fromJSON: each) message at: ''payload'') ].
            watching setFunction: aFunction tag: tag.
            aFunction session evaluate: (self attachSourceFor: aFunction tag: tag).
            ^ watching'.
        hook class compile: 'nextTag
            Issued := (Issued ifNil: [ 0 ]) + 1.
            ^ ''hook'' , Issued printString'.
        hook class compile: 'attachSourceFor: aFunction tag: aTag
            ^ ''(globalThis.lumaHooks = globalThis.lumaHooks || {})["'' , aTag , ''"] = Interceptor.attach(ptr("'' , aFunction addressString , ''"), { onEnter(args) { send({ hook: "'' , aTag , ''", thread: this.threadId, returnAddress: this.returnAddress.toString(), args: [args[0].toString(), args[1].toString(), args[2].toString(), args[3].toString()] }); } });'''.
        hook class compile: 'detachSourceFor: aTag
            ^ ''globalThis.lumaHooks["'' , aTag , ''"].detach(); delete globalThis.lumaHooks["'' , aTag , ''"];'''.
        hook compile: 'setFunction: aFunction tag: aTag
            function := aFunction.
            tag := aTag'.
        hook compile: 'function ^ function'.
        hook compile: 'stop
            self isActive ifFalse: [ ^ self ].
            function session evaluate: (self class detachSourceFor: tag).
            super stop'.
        hook compile: 'printOn: aStream
            aStream nextPutAll: ''LumaHook(''; nextPutAll: function name; nextPut: $).
            self isActive ifFalse: [ aStream nextPutAll: '' stopped'' ].
            self error ifNotNil: [ :message | aStream nextPutAll: '': ''; nextPutAll: message ]'.

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
