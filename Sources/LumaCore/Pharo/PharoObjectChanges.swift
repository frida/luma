import Foundation
import Observation

@Observable
@MainActor
public final class PharoObjectChanges {
    public static let shared = PharoObjectChanges()

    public private(set) var generations: [Int: Int] = [:]

    @ObservationIgnored private var pending: Set<Int> = []
    @ObservationIgnored private var isFlushScheduled = false

    public func generation(of handle: Int) -> Int {
        generations[handle] ?? 0
    }

    func noteChange(of handle: Int) {
        pending.insert(handle)
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(16))
            flush()
        }
    }

    private func flush() {
        for handle in pending {
            generations[handle, default: 0] += 1
        }
        pending = []
        isFlushScheduled = false
    }
}

@_cdecl("luma_object_changed")
public func luma_object_changed(_ handle: Int32) {
    Task { @MainActor in
        PharoObjectChanges.shared.noteChange(of: Int(handle))
    }
}
