import Foundation
import SwiftyPharo

/// What a Pharo result looked like when it was evaluated, kept so a notebook
/// still shows its results with no VM running — offline, or on a peer that
/// received the entry over collaboration.
public struct PharoSnapshot: Codable, Sendable, Equatable {
    public var printString: String
    public var className: String
    public var views: [View]

    public struct View: Codable, Sendable, Equatable {
        public var title: String
        public var methodSelector: String
        public var content: Content
        public var priority: Int

        public enum Content: Codable, Sendable, Equatable {
            case items(shown: [String], total: Int)
            case text(String)
            case empty
        }
    }

    /// How much of a long view is worth keeping; the live inspector pages the
    /// rest when a VM is around.
    static let retainedItemCount = 100

    public init(printString: String, className: String, views: [View]) {
        self.printString = printString
        self.className = className
        self.views = views
    }
}

extension PharoSnapshot {
    public static func capture(of object: PharoObject, using runtime: PharoRuntime) async throws -> PharoSnapshot {
        var views: [View] = []

        for declaration in try await runtime.views(of: object) {
            views.append(
                View(
                    title: declaration.title,
                    methodSelector: declaration.methodSelector,
                    content: try await content(of: declaration, in: object, using: runtime),
                    priority: declaration.priority
                )
            )
        }

        return PharoSnapshot(printString: object.printString, className: object.className, views: views)
    }

    private static func content(
        of declaration: PharoViewDeclaration,
        in object: PharoObject,
        using runtime: PharoRuntime
    ) async throws -> View.Content {
        if let text = declaration.text {
            return .text(text)
        }

        let page = try await runtime.items(
            of: object,
            view: declaration.methodSelector,
            from: 0,
            count: retainedItemCount
        )
        if page.total == 0 {
            return .empty
        }
        return .items(shown: page.items, total: page.total)
    }
}
