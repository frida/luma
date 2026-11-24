import Foundation

@MainActor
enum ObjectChatTools {
    static func register(in catalog: ToolCatalog, engine: Engine) {
        registerEvaluate(in: catalog, engine: engine)
        registerView(in: catalog, engine: engine)
        registerObjects(in: catalog, engine: engine)
    }

    private static func registerEvaluate(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: ObjectChats.evaluateTool,
            description: """
                Evaluate one Smalltalk expression in the user's own image, with `self` bound to `o1`, the object \
                this chat is about. Earlier results are reached through bindings: each names an object id and the \
                variable the code calls it by. Answers the new object's id, class, print string, views and \
                instance variables, or the compile error and where in the code it is.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"code":{"type":"string","description":"One Smalltalk expression"},"bindings":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"object_id":{"type":"string"}},"required":["name","object_id"],"additionalProperties":false}}},"required":["code"],"additionalProperties":false}
                """,
            isObserve: false,
            needs: [.chatObjects]
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return MissionTools.errorResult("engine unavailable", code: .unavailable) }
            return await engine.objectChats.evaluate(invocation)
        }
    }

    private static func registerView(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: ObjectChats.viewTool,
            description: """
                Read one of an object's views -- a tab the inspector shows -- without running code: its rows \
                (from is 0-based), its text, or a summary of its graph or chart. An object not live in this Luma \
                is read from the snapshot taken when it was made.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"object_id":{"type":"string"},"view":{"type":"string","description":"A view's title or selector"},"from":{"type":"integer","default":0},"count":{"type":"integer","default":50}},"required":["object_id","view"],"additionalProperties":false}
                """,
            isObserve: true,
            needs: [.chatObjects]
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return MissionTools.errorResult("engine unavailable", code: .unavailable) }
            return await engine.objectChats.view(invocation)
        }
    }

    private static func registerObjects(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: ObjectChats.objectsTool,
            description: "The objects this chat holds: id, name, class, print string, and whether each is live in this Luma.",
            inputSchemaJSON: """
                {"type":"object","properties":{},"additionalProperties":false}
                """,
            isObserve: true,
            needs: [.chatObjects]
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return MissionTools.errorResult("engine unavailable", code: .unavailable) }
            return engine.objectChats.objectsList(invocation)
        }
    }
}
