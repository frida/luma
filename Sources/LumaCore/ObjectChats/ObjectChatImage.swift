import Foundation
import SwiftyPharo

@MainActor
struct ObjectChatImage {
    let runtime: PharoRuntime
    let chatID: UUID

    private var chat: String { "(LumaChat open: '\(chatID.uuidString)')" }

    func column() async throws -> PharoObject {
        try await runtime.evaluate(chat)
    }

    func retitle(_ title: String) async throws {
        try await runtime.release(
            try await runtime.evaluate(
                "LumaChat at: '\(chatID.uuidString)' ifPresent: [ :held | held title: \(Self.literal(title)) ] ifAbsent: [ nil ]"))
    }

    func store(_ object: PharoObject, as objectID: String, named name: String?) async throws {
        let named = name.map(Self.literal) ?? "nil"
        try await runtime.release(
            try await runtime.evaluate(
                "\(chat) store: (SwpBridge current session objectAt: \(object.handle)) as: '\(objectID)' named: \(named)"))
    }

    func object(_ objectID: String) async throws -> PharoObject {
        try await runtime.evaluate("\(chat) objectAt: '\(objectID)'")
    }

    func evaluate(_ code: String, bindings: [String: String], as objectID: String, runningFor callID: UUID) async throws -> PharoObject {
        let bound = bindings.map { "\(Self.literal($0.key)) -> '\($0.value)'" }.joined(separator: ". ")
        return try await runtime.evaluate(
            "\(chat) evaluate: \(Self.literal(code)) bindings: { \(bound) } asDictionary as: '\(objectID)'",
            runningFor: callID)
    }

    func slots(of objectID: String) async throws -> [(name: String, value: String)] {
        let listed = try await runtime.evaluate(
            """
            | object | object := \(chat) objectAt: '\(objectID)'.
            STONJSON toString: (object class allInstVarNames collect: [ :each |
                { each. (object instVarNamed: each) printStringLimitedTo: 120 } ])
            """)
        try await runtime.release(listed)
        let pairs = try JSONSerialization.jsonObject(with: Data(Self.string(printedAs: listed.printString).utf8)) as! [[String]]
        return pairs.map { (name: $0[0], value: $0[1]) }
    }

    func instructionIdentity(of object: PharoObject) async throws -> (sessionID: UUID, anchor: AddressAnchor)? {
        guard object.className == "LumaInstruction" else { return nil }
        let identity = try await runtime.evaluate(
            """
            | instruction | instruction := SwpBridge current session objectAt: \(object.handle).
            STONJSON toString: { instruction session id. instruction anchor }
            """)
        try await runtime.release(identity)
        let pair = try JSONSerialization.jsonObject(with: Data(Self.string(printedAs: identity.printString).utf8)) as! [Any]
        return (UUID(uuidString: pair[0] as! String)!, try AddressAnchor.fromJSON(pair[1] as! JSONObject))
    }

    func rebuildInstruction(sessionID: UUID, anchor: AddressAnchor) async throws -> PharoObject {
        let anchorJSON = String(decoding: try JSONSerialization.data(withJSONObject: anchor.toJSON()), as: UTF8.self)
        return try await runtime.evaluate(
            """
            (LumaProject sessions items detect: [ :each | each id = '\(sessionID.uuidString)' ])
                instructionAnchoredTo: (STONJSON fromString: \(Self.literal(anchorJSON)))
            """)
    }

    func project() async throws -> PharoObject {
        try await runtime.evaluate("LumaProject")
    }

    func location(of object: PharoObject) async throws -> (chatID: UUID, objectID: String)? {
        let located = try await runtime.evaluate(
            "STONJSON toString: (LumaChat locate: (SwpBridge current session objectAt: \(object.handle)))")
        try await runtime.release(located)
        guard
            let pair = try JSONSerialization.jsonObject(
                with: Data(Self.string(printedAs: located.printString).utf8), options: .fragmentsAllowed) as? [String]
        else { return nil }
        return (UUID(uuidString: pair[0])!, pair[1])
    }

    func forget() async throws {
        try await runtime.release(try await runtime.evaluate("LumaChat forget: '\(chatID.uuidString)'"))
    }

    private static func literal(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func string(printedAs literal: String) -> String {
        String(literal.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
}
