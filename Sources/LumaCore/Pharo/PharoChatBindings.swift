enum PharoChatBindings {
    static let source = """
        | chat |
        chat := Object << #LumaChat slots: { #id. #title. #objects. #names }; sharedVariables: { #Registry }; package: 'Luma'; install.
        chat class compile: 'at: anID
            ^ self registry at: anID'.
        chat class compile: 'at: anID ifPresent: aPresentBlock ifAbsent: anAbsentBlock
            ^ self registry at: anID ifPresent: aPresentBlock ifAbsent: anAbsentBlock'.
        chat class compile: 'at: anID ifAbsentPut: aBlock
            ^ self registry at: anID ifAbsentPut: aBlock'.
        chat class compile: 'open: anID
            ^ self at: anID ifAbsentPut: [
                self new
                    setID: anID;
                    title: (LumaHost request: { #op -> ''object_chat_title''. #chat -> anID } asDictionary);
                    yourself ]'.
        chat class compile: 'locate: anObject
            self registry keysAndValuesDo: [ :chatID :each |
                (each idOf: anObject) ifNotNil: [ :objectID | ^ { chatID. objectID } ] ].
            ^ nil'.
        chat class compile: 'forget: anID
            self registry removeKey: anID ifAbsent: [ nil ]'.
        chat class compile: 'registry
            Registry ifNil: [ Registry := Dictionary new ].
            ^ Registry'.
        chat class compile: 'deadline
            ^ 10 seconds'.
        chat compile: 'setID: anID
            id := anID.
            objects := OrderedDictionary new.
            names := Dictionary new'.
        chat compile: 'id ^ id'.
        chat compile: 'title: aString
            title := aString.
            self lumaChanged'.
        chat compile: 'store: anObject as: anObjectID named: aName
            objects at: anObjectID put: anObject.
            aName ifNotNil: [ names at: anObjectID put: aName ].
            self lumaChanged.
            ^ anObject'.
        chat compile: 'objectAt: anObjectID
            ^ objects at: anObjectID'.
        chat compile: 'holds: anObjectID
            ^ objects includesKey: anObjectID'.
        chat compile: 'idOf: anObject
            ^ (objects associations detect: [ :each | each value == anObject ] ifNone: [ ^ nil ]) key'.
        chat compile: 'evaluate: aSource bindings: aDictionary as: anObjectID
            | workspace |
            workspace := SwpWorkspace new.
            aDictionary keysAndValuesDo: [ :name :boundID |
                workspace addBinding: (WorkspaceVariable key: name asSymbol value: (self objectAt: boundID)) ].
            ^ self
                store: ([ Smalltalk compiler
                        receiver: (objects at: ''o1'' ifAbsent: [ nil ]);
                        requestor: workspace;
                        source: aSource;
                        evaluate ]
                    valueWithin: self class deadline
                    onTimeout: [ LumaHostError signal: ''the expression did not finish within '' , self class deadline asSeconds printString , '' seconds'' ])
                as: anObjectID
                named: nil'.
        chat compile: 'printOn: aStream
            | shown |
            shown := title ifNil: [ ''Chat'' ].
            aStream nextPutAll: ((shown beginsWith: ''Chat about '') ifTrue: [ shown allButFirst: 5 ] ifFalse: [ shown ])'.
        chat compile: 'gtChatFor: aView
            <gtView>
            ^ (LumaView new kindName: ''lumaChat'')
                title: ''Chat'';
                priority: 1;
                text: [ id ];
                yourself'.
        chat compile: 'gtObjectsFor: aView
            <gtView>
            ^ aView columnedList
                title: ''Objects'';
                priority: 2;
                items: [ objects associations ];
                column: ''Id'' text: [ :each | each key ];
                column: ''Name'' text: [ :each | names at: each key ifAbsent: [ '''' ] ];
                column: ''Object'' text: [ :each | each value printString ];
                send: [ :each | each value ]'.
        LumaProject class compile: 'gtSessionsFor: aView
            <gtView>
            ^ aView forward
                title: ''Sessions'';
                priority: 1;
                object: [ self sessions ];
                view: #gtSessionsFor:'.
        LumaProject class compile: 'gtNotebookFor: aView
            <gtView>
            ^ aView forward
                title: ''Notebook'';
                priority: 2;
                object: [ self notebookEntries ];
                view: #gtEntriesFor:'.
        LumaProject class compile: 'gtEventsFor: aView
            <gtView>
            ^ aView forward
                title: ''Events'';
                priority: 3;
                object: [ self events ];
                view: #gtEventsFor:'.
        chat
        """
}
