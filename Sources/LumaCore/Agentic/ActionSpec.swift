import Foundation

public struct ActionSpec: Sendable {
    public var name: String
    public var description: String
    public var inputSchemaJSON: String
    public var isObserve: Bool
    public var requiresSession: Bool

    public init(
        name: String,
        description: String,
        inputSchemaJSON: String,
        isObserve: Bool,
        requiresSession: Bool
    ) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
        self.isObserve = isObserve
        self.requiresSession = requiresSession
    }

    public func toToolSpec(cacheBoundary: Bool = false) -> LLMToolSpec {
        LLMToolSpec(
            name: name,
            description: description,
            inputSchemaJSON: inputSchemaJSON,
            cacheBoundary: cacheBoundary
        )
    }
}

public struct ActionResult: Sendable {
    public var summary: String
    public var resultJSON: String
    public var isError: Bool

    public init(summary: String, resultJSON: String, isError: Bool = false) {
        self.summary = summary
        self.resultJSON = resultJSON
        self.isError = isError
    }
}

public struct ActionInvocation: @unchecked Sendable {
    public var args: [String: Any]
    public var mission: Mission
    public var sessionID: UUID?
    public var toolCallID: String

    public init(args: [String: Any], mission: Mission, sessionID: UUID?, toolCallID: String) {
        self.args = args
        self.mission = mission
        self.sessionID = sessionID
        self.toolCallID = toolCallID
    }
}
