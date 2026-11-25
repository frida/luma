import SwiftUI

struct PharoColumnPresence {
    let handle: Int
    let close: () -> Void

    func whenClosed(_ action: @escaping () -> Void) {
        PharoColumnLifetimes.shared.whenGone(handle, action)
    }
}

@MainActor
final class PharoColumnLifetimes {
    static let shared = PharoColumnLifetimes()

    private var shownCounts: [Int: Int] = [:]
    private var endings: [Int: () -> Void] = [:]

    func appeared(_ handle: Int) {
        shownCounts[handle, default: 0] += 1
    }

    func disappeared(_ handle: Int) {
        shownCounts[handle, default: 1] -= 1
        DispatchQueue.main.async { [self] in
            guard shownCounts[handle, default: 0] <= 0 else { return }
            shownCounts[handle] = nil
            endings.removeValue(forKey: handle)?()
        }
    }

    func whenGone(_ handle: Int, _ action: @escaping () -> Void) {
        endings[handle] = action
    }
}
