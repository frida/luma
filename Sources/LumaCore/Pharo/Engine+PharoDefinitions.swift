import Foundation

extension Engine {
    func recordPharoClass(_ request: [String: Any]) throws -> Any {
        try store.save(
            PharoClassDefinition(
                name: try pharoArgument("name", of: request),
                superclass: try pharoArgument("superclass", of: request),
                package: try pharoArgument("package", of: request),
                tag: try pharoArgument("tag", of: request),
                instanceVariables: try pharoArgument("instanceVariables", of: request),
                classVariables: try pharoArgument("classVariables", of: request),
                classInstanceVariables: try pharoArgument("classInstanceVariables", of: request)))
        return NSNull()
    }

    func forgetPharoClass(_ request: [String: Any]) throws -> Any {
        try store.deletePharoClassDefinition(named: try pharoArgument("name", of: request))
        return NSNull()
    }

    func recordPharoMethod(_ request: [String: Any]) throws -> Any {
        try store.save(
            PharoMethodDefinition(
                className: try pharoArgument("class", of: request),
                side: try pharoArgument("side", of: request),
                selector: try pharoArgument("selector", of: request),
                category: try pharoArgument("category", of: request),
                source: try pharoArgument("source", of: request)))
        return NSNull()
    }

    func forgetPharoMethod(_ request: [String: Any]) throws -> Any {
        try store.deletePharoMethodDefinition(
            className: try pharoArgument("class", of: request),
            side: try pharoArgument("side", of: request),
            selector: try pharoArgument("selector", of: request))
        return NSNull()
    }
}
