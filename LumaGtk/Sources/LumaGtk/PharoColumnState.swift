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
    /// Which column is the current one, or nothing when the page is; the strip
    /// draws it brightest and a drill moves it to the newest.
    private(set) var shown: Int?

    func startOver(at object: PharoObject) {
        objects = [object]
        collapsed = []
        maximized = nil
        shown = 0
    }

    func open(_ object: PharoObject, from depth: Int) {
        objects = Array(objects.prefix(depth + 1)) + [object]
        shown = objects.count - 1
        keepStatesOfPresent()
    }

    func close(from depth: Int) {
        objects = Array(objects.prefix(depth))
        shown = objects.isEmpty ? nil : min(shown ?? 0, objects.count - 1)
        keepStatesOfPresent()
    }

    func show(_ depth: Int?) {
        shown = depth
    }

    func clear() {
        objects = []
        collapsed = []
        maximized = nil
        shown = nil
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
