import SwiftyPharo

@MainActor
public protocol PharoViewSource {
    func views() async throws -> [PharoViewDeclaration]
    func items(view: String, from: Int, count: Int, filter: String?) async throws -> PharoItemsPage
    func drill(view: String, index: Int, filter: String?) async throws -> PharoObject
}

public struct PharoObjectViews: PharoViewSource {
    public let runtime: PharoRuntime
    public let object: PharoObject

    public init(runtime: PharoRuntime, object: PharoObject) {
        self.runtime = runtime
        self.object = object
    }

    public func views() async throws -> [PharoViewDeclaration] {
        try await runtime.views(of: object)
    }

    public func items(view: String, from: Int, count: Int, filter: String?) async throws -> PharoItemsPage {
        try await runtime.items(of: object, view: view, from: from, count: count, filter: filter)
    }

    public func drill(view: String, index: Int, filter: String?) async throws -> PharoObject {
        try await runtime.drillInto(object, view: view, index: index, filter: filter)
    }
}

public struct InstrumentViewSource: PharoViewSource {
    public let instrumentViews: InstrumentViews
    public let key: InstrumentViews.Key

    public init(instrumentViews: InstrumentViews, key: InstrumentViews.Key) {
        self.instrumentViews = instrumentViews
        self.key = key
    }

    public func views() async throws -> [PharoViewDeclaration] {
        try await instrumentViews.declarations(of: key)
    }

    public func items(view: String, from: Int, count: Int, filter: String?) async throws -> PharoItemsPage {
        try await instrumentViews.items(of: key, view: view, from: from, count: count, filter: filter)
    }

    public func drill(view: String, index: Int, filter: String?) async throws -> PharoObject {
        try await instrumentViews.drill(into: key, view: view, index: index, filter: filter)
    }
}
