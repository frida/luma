import Foundation
import SwiftyPharo

/// The chain of objects a moldable inspection has drilled through, and how each
/// column was left -- shrunk to a strip, or blown up to fill. Mirrors the
/// SwiftUI column path; the widgets that read it are GTK's.
@MainActor
final class PharoColumnState {
    private(set) var objects: [PharoObject] = []
    private(set) var collapsed: Set<Int> = []
    private(set) var maximized: Int?

    func startOver(at object: PharoObject) {
        objects = [object]
        collapsed = []
        maximized = nil
    }

    func open(_ object: PharoObject, from depth: Int) {
        objects = Array(objects.prefix(depth + 1)) + [object]
        keepStatesOfPresent()
    }

    func close(from depth: Int) {
        objects = Array(objects.prefix(depth))
        keepStatesOfPresent()
    }

    func clear() {
        objects = []
        collapsed = []
        maximized = nil
    }

    func isCollapsed(_ handle: Int) -> Bool {
        collapsed.contains(handle)
    }

    func toggleCollapsed(_ handle: Int) {
        if collapsed.contains(handle) {
            collapsed.remove(handle)
        } else {
            collapsed.insert(handle)
        }
    }

    func isMaximized(_ handle: Int) -> Bool {
        maximized == handle
    }

    func toggleMaximized(_ handle: Int) {
        maximized = maximized == handle ? nil : handle
    }

    private func keepStatesOfPresent() {
        let present = Set(objects.map(\.handle))
        collapsed.formIntersection(present)
        if let handle = maximized, !present.contains(handle) {
            maximized = nil
        }
    }
}
