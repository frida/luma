import Foundation
import SwiftyPharo

/// What a mission can do with the image: run Smalltalk, walk what it produced
/// through the views the objects declare, read and write the classes those
/// objects come from, and leave snippets on the playground page for whoever
/// reads the project afterwards.
///
/// Objects live in the image until released, so every tool that hands one back
/// gives a `handle` the workspace keeps, and `pharo_release` lets it go.
extension MissionTools {
    static func registerPharo(in catalog: ToolCatalog, engine: Engine) {
        registerPharoEval(in: catalog, engine: engine)
        registerPharoInspect(in: catalog, engine: engine)
        registerPharoListItems(in: catalog, engine: engine)
        registerPharoDrill(in: catalog, engine: engine)
        registerPharoRelease(in: catalog, engine: engine)
        registerPharoBrowseClass(in: catalog, engine: engine)
        registerPharoReadMethod(in: catalog, engine: engine)
        registerPharoCompileMethod(in: catalog, engine: engine)
        registerPharoDefineClass(in: catalog, engine: engine)
        registerPharoFindReferences(in: catalog, engine: engine)
        registerPharoFormatSource(in: catalog, engine: engine)
        registerPharoRunExample(in: catalog, engine: engine)
        registerPharoListSnippets(in: catalog, engine: engine)
        registerPharoAddSnippet(in: catalog, engine: engine)
    }

    // MARK: - pharo_eval

    private static func registerPharoEval(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_eval",
            description: """
                Evaluate a Smalltalk expression in the embedded Pharo image and hold on to what it \
                answers. The result comes back as a handle other pharo_* tools take. LumaProject \
                reaches the host: `LumaProject sessions`, `LumaProject notebookEntries`, \
                `LumaProject events`. Use pharo_inspect to see what a result can show.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"source":{"type":"string","description":"Smalltalk to evaluate, e.g. \\"LumaProject sessions\\""}},"required":["source"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let source = invocation.args["source"] as? String, !source.isEmpty else {
                return errorResult("source is required", code: .invalidInput)
            }
            return await withPharo(engine) { runtime in
                let produced = engine.pharo.remember(try await runtime.evaluate(source))
                return makeResult(
                    jsonObject: describe(produced),
                    summary: "Evaluated to \(produced.printString)")
            }
        }
    }

    // MARK: - pharo_inspect

    private static func registerPharoInspect(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_inspect",
            description: """
                List the views an object declares -- the tabs Glamorous Toolkit would show it \
                under. A view with columns is paged with pharo_list_items; one with text carries \
                it here. Takes a handle from pharo_eval or pharo_drill.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"handle":{"type":"integer"}},"required":["handle"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let handle = invocation.args["handle"] as? Int else {
                return errorResult("handle is required", code: .invalidInput)
            }
            return await withPharo(engine) { runtime in
                let object = try engine.pharo.object(handle: handle)
                let views = try await runtime.views(of: object)
                let described: [[String: Any]] = views.map { view in
                    var entry: [String: Any] = [
                        "view": view.viewName,
                        "title": view.title,
                        "selector": view.methodSelector,
                    ]
                    entry["columns"] = view.columns
                    entry["text"] = view.text
                    entry["has_graph"] = view.graph != nil
                    entry["has_chart"] = view.chart != nil
                    entry["has_canvas"] = view.canvas != nil
                    return entry.compactMapValues { $0 }
                }
                return makeResult(
                    jsonObject: ["object": describe(object), "views": described],
                    summary: "\(views.count) view\(views.count == 1 ? "" : "s") on \(object.className)")
            }
        }
    }

    // MARK: - pharo_list_items

    private static func registerPharoListItems(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_list_items",
            description: """
                Page the rows of one of an object's views. Each row is a cell per column the view \
                declares, and the row index is what pharo_drill opens. Pass filter to narrow the \
                rows the way the inspector's search field does.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"handle":{"type":"integer"},"view":{"type":"string","description":"A view name from pharo_inspect"},"from":{"type":"integer","default":0},"count":{"type":"integer","default":50},"filter":{"type":"string"}},"required":["handle","view"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let handle = invocation.args["handle"] as? Int,
                  let view = invocation.args["view"] as? String
            else { return errorResult("handle and view are required", code: .invalidInput) }
            let from = invocation.args["from"] as? Int ?? 0
            let count = min(invocation.args["count"] as? Int ?? 50, 200)
            let filter = invocation.args["filter"] as? String

            return await withPharo(engine) { runtime in
                let object = try engine.pharo.object(handle: handle)
                let page = try await runtime.items(
                    of: object, view: view, from: from, count: count, filter: filter)
                let rows: [[String: Any]] = page.items.enumerated().map { offset, cells in
                    ["index": from + offset, "cells": cells.map { $0.text ?? "" }]
                }
                return makeResult(
                    jsonObject: ["total": page.total, "from": from, "rows": rows],
                    summary: "Rows \(from)..<\(from + rows.count) of \(page.total)")
            }
        }
    }

    // MARK: - pharo_drill

    private static func registerPharoDrill(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_drill",
            description: """
                Open the object behind a row of a view, the way clicking that row in the inspector \
                would. Answers a handle of its own, so a walk into a structure is a chain of these.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"handle":{"type":"integer"},"view":{"type":"string"},"index":{"type":"integer","description":"Row index as reported by pharo_list_items"},"filter":{"type":"string","description":"The same filter the rows were listed with, so the index still points where it did"}},"required":["handle","view","index"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let handle = invocation.args["handle"] as? Int,
                  let view = invocation.args["view"] as? String,
                  let index = invocation.args["index"] as? Int
            else { return errorResult("handle, view and index are required", code: .invalidInput) }
            let filter = invocation.args["filter"] as? String

            return await withPharo(engine) { runtime in
                let object = try engine.pharo.object(handle: handle)
                let drilled = engine.pharo.remember(
                    try await runtime.drillInto(object, view: view, index: index, filter: filter))
                return makeResult(
                    jsonObject: describe(drilled),
                    summary: "Opened \(drilled.printString)")
            }
        }
    }

    // MARK: - pharo_release

    private static func registerPharoRelease(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_release",
            description: """
                Let go of an object the image was holding for you. Do this once a handle is no \
                longer needed; a long mission that never releases keeps everything it touched alive.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"handle":{"type":"integer"}},"required":["handle"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let handle = invocation.args["handle"] as? Int else {
                return errorResult("handle is required", code: .invalidInput)
            }
            return await withPharo(engine) { _ in
                try await engine.pharo.release(handle: handle)
                return makeResult(jsonObject: ["released": handle], summary: "Released \(handle)")
            }
        }
    }

    // MARK: - pharo_browse_class

    private static func registerPharoBrowseClass(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_browse_class",
            description: """
                The class of an object as its coder shows it: package, superclass, definition, \
                comment, the selectors it implements on each side, and which of them are examples. \
                Method sources are left out; read one with pharo_read_method.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"handle":{"type":"integer","description":"Any object; its class is browsed"},"class_name":{"type":"string","description":"Browse this class instead of an object's"}},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            return await withPharo(engine) { runtime in
                let subject = try await browsedClass(of: invocation, engine: engine, runtime: runtime)
                let info = try await runtime.classBrowser(of: subject)
                let examples = Set(info.examples.map(\.id))
                let methods: [[String: Any]] = info.methods.map { method in
                    [
                        "selector": method.selector,
                        "side": method.side,
                        "category": method.category,
                        "is_example": examples.contains(method.id),
                    ]
                }
                let described: [String: Any] = [
                    "name": info.name,
                    "superclass": info.superclass,
                    "package": info.package,
                    "tag": info.tag,
                    "definition": info.definition,
                    "comment": info.comment,
                    "methods": methods,
                ]
                return makeResult(
                    jsonObject: described,
                    summary: "\(info.name): \(info.methods.count) method\(info.methods.count == 1 ? "" : "s")")
            }
        }
    }

    // MARK: - pharo_read_method

    private static func registerPharoReadMethod(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_read_method",
            description: "The source of one method, as pharo_browse_class listed it.",
            inputSchemaJSON: """
                {"type":"object","properties":{"handle":{"type":"integer"},"class_name":{"type":"string"},"selector":{"type":"string"},"side":{"type":"string","enum":["instance","class"],"default":"instance"}},"required":["selector"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let selector = invocation.args["selector"] as? String else {
                return errorResult("selector is required", code: .invalidInput)
            }
            let side = invocation.args["side"] as? String ?? "instance"
            return await withPharo(engine) { runtime in
                let subject = try await browsedClass(of: invocation, engine: engine, runtime: runtime)
                let info = try await runtime.classBrowser(of: subject)
                guard let method = info.methods.first(where: { $0.selector == selector && $0.side == side })
                else {
                    return errorResult("\(info.name) has no \(side)-side \(selector)", code: .notFound)
                }
                return makeResult(
                    jsonObject: [
                        "class": info.name,
                        "selector": method.selector,
                        "side": method.side,
                        "category": method.category,
                        "source": method.source,
                    ],
                    summary: "\(info.name)>>\(selector)")
            }
        }
    }

    // MARK: - pharo_compile_method

    private static func registerPharoCompileMethod(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_compile_method",
            description: """
                Install a method on a class, source and all, the way the coder's save does. The \
                source starts with the message pattern, e.g. "double\\n\\t^ self * 2".
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"handle":{"type":"integer"},"class_name":{"type":"string"},"side":{"type":"string","enum":["instance","class"],"default":"instance"},"category":{"type":"string","default":"as yet unclassified"},"source":{"type":"string"}},"required":["source"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let source = invocation.args["source"] as? String, !source.isEmpty else {
                return errorResult("source is required", code: .invalidInput)
            }
            let side = invocation.args["side"] as? String ?? "instance"
            let category = invocation.args["category"] as? String ?? "as yet unclassified"
            return await withPharo(engine) { runtime in
                let subject = try await browsedClass(of: invocation, engine: engine, runtime: runtime)
                let method = try await runtime.compileMethod(
                    in: subject, side: side, category: category, source: source)
                return makeResult(
                    jsonObject: [
                        "selector": method.selector,
                        "side": method.side,
                        "category": method.category,
                    ],
                    summary: "Compiled \(method.selector)")
            }
        }
    }

    // MARK: - pharo_define_class

    private static func registerPharoDefineClass(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_define_class",
            description: "Create a class, the way the playground's \"Create class\" fix does. Answers a handle on it.",
            inputSchemaJSON: """
                {"type":"object","properties":{"name":{"type":"string"},"superclass":{"type":"string","default":"Object"},"package":{"type":"string","default":"Playground"},"tag":{"type":"string","default":""},"instance_variables":{"type":"string","description":"Space-separated slot names","default":""},"class_variables":{"type":"string","default":""},"class_instance_variables":{"type":"string","default":""}},"required":["name"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let name = invocation.args["name"] as? String, !name.isEmpty else {
                return errorResult("name is required", code: .invalidInput)
            }
            return await withPharo(engine) { runtime in
                let made = engine.pharo.remember(
                    try await runtime.defineClass(
                        name: name,
                        superclass: invocation.args["superclass"] as? String ?? "Object",
                        package: invocation.args["package"] as? String ?? "Playground",
                        tag: invocation.args["tag"] as? String ?? "",
                        instanceVariables: invocation.args["instance_variables"] as? String ?? "",
                        classVariables: invocation.args["class_variables"] as? String ?? "",
                        classInstanceVariables: invocation.args["class_instance_variables"] as? String ?? ""))
                return makeResult(jsonObject: describe(made), summary: "Defined \(name)")
            }
        }
    }

    // MARK: - pharo_find_references

    private static func registerPharoFindReferences(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_find_references",
            description: """
                Who sends a selector, or who implements it. Answers a handle on the method \
                collection, which pharo_inspect and pharo_list_items page through.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"selector":{"type":"string"},"kind":{"type":"string","enum":["senders","implementors"],"default":"implementors"}},"required":["selector"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let selector = invocation.args["selector"] as? String, !selector.isEmpty else {
                return errorResult("selector is required", code: .invalidInput)
            }
            let kindName = invocation.args["kind"] as? String ?? "implementors"
            guard let kind = PharoBrowseKind(rawValue: kindName) else {
                return errorResult("kind must be senders or implementors", code: .invalidInput)
            }
            return await withPharo(engine) { runtime in
                // The image reads the selector under a cursor rather than being
                // handed one, so the selector alone stands in for the source.
                let answer = try await runtime.browse(kind, source: selector, at: 1)
                guard let found = answer.result else {
                    return errorResult("nothing found for \(selector)", code: .notFound)
                }
                let remembered = engine.pharo.remember(found)
                return makeResult(
                    jsonObject: describe(remembered),
                    summary: "\(kindName) of \(selector): \(remembered.display)")
            }
        }
    }

    // MARK: - pharo_format_source

    private static func registerPharoFormatSource(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_format_source",
            description: "Pretty-print Smalltalk the way the image would, before saving it into a snippet or a method.",
            inputSchemaJSON: """
                {"type":"object","properties":{"source":{"type":"string"}},"required":["source"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let source = invocation.args["source"] as? String else {
                return errorResult("source is required", code: .invalidInput)
            }
            return await withPharo(engine) { runtime in
                let formatted = try await runtime.format(source: source)
                return makeResult(jsonObject: ["source": formatted], summary: "Formatted")
            }
        }
    }

    // MARK: - pharo_run_example

    private static func registerPharoRunExample(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_run_example",
            description: """
                Run one of a class's examples -- the methods pharo_browse_class marks is_example -- \
                and hold on to what it answers. Examples are the shortest way to see what a class \
                is for.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"handle":{"type":"integer"},"class_name":{"type":"string"},"selector":{"type":"string"},"side":{"type":"string","enum":["instance","class"],"default":"class"}},"required":["selector"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let selector = invocation.args["selector"] as? String else {
                return errorResult("selector is required", code: .invalidInput)
            }
            let side = invocation.args["side"] as? String ?? "class"
            return await withPharo(engine) { runtime in
                let subject = try await browsedClass(of: invocation, engine: engine, runtime: runtime)
                let info = try await runtime.classBrowser(of: subject)
                guard let example = info.examples.first(where: { $0.selector == selector && $0.side == side })
                else {
                    return errorResult("\(info.name) has no example \(selector)", code: .notFound)
                }
                let produced = engine.pharo.remember(try await runtime.runExample(example, of: subject))
                return makeResult(
                    jsonObject: describe(produced),
                    summary: "\(info.name)>>\(selector) answered \(produced.printString)")
            }
        }
    }

    // MARK: - pharo_list_snippets

    private static func registerPharoListSnippets(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_list_snippets",
            description: "The Smalltalk snippets on the project's playground page, as the reader left them.",
            inputSchemaJSON: """
                {"type":"object","properties":{},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] _ in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let snippets = engine.pharoSnippets
            let described: [[String: Any]] = snippets.map { snippet in
                ["id": snippet.id.uuidString, "source": snippet.source]
            }
            return makeResult(
                jsonObject: described,
                summary: "\(snippets.count) snippet\(snippets.count == 1 ? "" : "s")")
        }
    }

    // MARK: - pharo_add_snippet

    private static func registerPharoAddSnippet(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pharo_add_snippet",
            description: """
                Leave a Smalltalk snippet on the playground page, where whoever opens the project \
                next can run it. Use this to hand over an expression worth keeping rather than one \
                you only needed once.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"source":{"type":"string"}},"required":["source"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let source = invocation.args["source"] as? String, !source.isEmpty else {
                return errorResult("source is required", code: .invalidInput)
            }
            let snippet = PharoPlaygroundSnippet(source: source)
            engine.setPharoSnippets(engine.pharoSnippets + [snippet])
            return makeResult(
                jsonObject: ["id": snippet.id.uuidString],
                summary: "Added a snippet to the playground")
        }
    }

    // MARK: - Reaching the image

    /// The image starts on first use and answers on its own thread, so every
    /// tool goes through here and reports what went wrong in the same shape.
    private static func withPharo(
        _ engine: Engine,
        _ body: (PharoRuntime) async throws -> ActionResult
    ) async -> ActionResult {
        do {
            return try await body(engine.pharo.started())
        } catch let error as PharoWorkspaceError {
            return errorResult(error.localizedDescription, code: .unavailable)
        } catch {
            return errorResult("\(error)", code: .failed)
        }
    }

    /// The class a tool works on: the one named, or the one behind a handle.
    private static func browsedClass(
        of invocation: ActionInvocation,
        engine: Engine,
        runtime: PharoRuntime
    ) async throws -> PharoObject {
        if let name = invocation.args["class_name"] as? String, !name.isEmpty {
            return engine.pharo.remember(try await runtime.evaluate(name))
        }
        guard let handle = invocation.args["handle"] as? Int else {
            throw PharoToolError.noSubject
        }
        let object = try engine.pharo.object(handle: handle)
        guard !object.isClass else { return object }
        return engine.pharo.remember(try await runtime.classObject(of: object))
    }

    private static func describe(_ object: PharoObject) -> [String: Any] {
        [
            "handle": object.handle,
            "class": object.className,
            "print_string": object.printString,
            "display": object.display,
            "is_class": object.isClass,
        ]
    }
}

enum PharoToolError: Error, LocalizedError {
    case noSubject

    var errorDescription: String? {
        "pass either class_name or a handle"
    }
}
