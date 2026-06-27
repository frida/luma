import Foundation

@MainActor
public final class ToolCatalog {
    public typealias Executor = @MainActor (ActionInvocation) async throws -> ActionResult

    private var specsByName: [String: ActionSpec] = [:]
    private var executorsByName: [String: Executor] = [:]
    private var registrationOrder: [String] = []
    private var cachedSpecs: [ActionSpec]?
    private var cachedToolSpecs: [LLMToolSpec]?

    public init() {}

    public func register(spec: ActionSpec, executor: @escaping Executor) {
        if specsByName[spec.name] == nil {
            registrationOrder.append(spec.name)
        }
        specsByName[spec.name] = spec
        executorsByName[spec.name] = executor
        cachedSpecs = nil
        cachedToolSpecs = nil
    }

    public func unregister(name: String) {
        specsByName.removeValue(forKey: name)
        executorsByName.removeValue(forKey: name)
        registrationOrder.removeAll { $0 == name }
        cachedSpecs = nil
        cachedToolSpecs = nil
    }

    public func spec(named name: String) -> ActionSpec? {
        specsByName[name]
    }

    public func specs() -> [ActionSpec] {
        if let cachedSpecs { return cachedSpecs }
        let specs = registrationOrder.compactMap { specsByName[$0] }
        cachedSpecs = specs
        return specs
    }

    public func toolSpecs() -> [LLMToolSpec] {
        if let cachedToolSpecs { return cachedToolSpecs }
        let specs = self.specs()
        let toolSpecs = specs.enumerated().map { index, spec in
            spec.toToolSpec(cacheBoundary: index == specs.count - 1)
        }
        cachedToolSpecs = toolSpecs
        return toolSpecs
    }

    public func execute(_ name: String, invocation: ActionInvocation) async throws -> ActionResult {
        guard let executor = executorsByName[name] else {
            throw LLMProviderError.capabilityUnsupported("unknown tool: \(name)")
        }
        return try await executor(invocation)
    }
}
