import Foundation

@MainActor
public final class ToolCatalog {
    public typealias Executor = @MainActor (ActionInvocation) async throws -> ActionResult

    private var specsByName: [String: ActionSpec] = [:]
    private var executorsByName: [String: Executor] = [:]
    private var registrationOrder: [String] = []

    public init() {}

    public func register(spec: ActionSpec, executor: @escaping Executor) {
        if specsByName[spec.name] == nil {
            registrationOrder.append(spec.name)
        }
        specsByName[spec.name] = spec
        executorsByName[spec.name] = executor
    }

    public func unregister(name: String) {
        specsByName.removeValue(forKey: name)
        executorsByName.removeValue(forKey: name)
        registrationOrder.removeAll { $0 == name }
    }

    public func spec(named name: String) -> ActionSpec? {
        specsByName[name]
    }

    public func specs() -> [ActionSpec] {
        registrationOrder.compactMap { specsByName[$0] }
    }

    public func toolSpecs() -> [LLMToolSpec] {
        let specs = self.specs()
        return specs.enumerated().map { index, spec in
            spec.toToolSpec(cacheBoundary: index == specs.count - 1)
        }
    }

    public func execute(_ name: String, invocation: ActionInvocation) async throws -> ActionResult {
        guard let executor = executorsByName[name] else {
            throw LLMProviderError.capabilityUnsupported("unknown tool: \(name)")
        }
        return try await executor(invocation)
    }
}
