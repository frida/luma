import Gtk

/// Keeps a `ScrolledWindow` pinned to the bottom as content grows.
///
/// Scrolling happens from a task scheduled by the adjustment's `changed`
/// signal, so it runs after layout — when `upper` reflects the new content
/// and setting `value` actually repositions the viewport. Poking the
/// adjustment right after appending instead races layout, reads a stale
/// `upper`, and either skips or fails to reposition until the next layout.
@MainActor
final class BottomScroller {
    private let scroll: ScrolledWindow
    private let threshold: Double
    private var pinned = true
    private var autoScrolling = false
    private var scheduled = false

    /// Notified when the user scrolls in or out of the bottom zone.
    var onPinnedChanged: ((Bool) -> Void)?

    var isPinned: Bool { pinned }

    init(_ scroll: ScrolledWindow, threshold: Double = 8.0) {
        self.scroll = scroll
        self.threshold = threshold
        guard let vadj = scroll.vadjustment else { return }
        vadj.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pinned else { return }
                self.schedule()
            }
        }
        vadj.onValueChanged { [weak self] adj in
            MainActor.assumeIsolated {
                guard let self, !self.autoScrolling else { return }
                self.setPinned((adj.upper - (adj.value + adj.pageSize)) < self.threshold)
            }
        }
    }

    /// Follow the bottom again; the next layout pass lands there.
    func pin() {
        setPinned(true)
    }

    func scrollToBottom() {
        setPinned(true)
        schedule()
    }

    private func setPinned(_ value: Bool) {
        guard value != pinned else { return }
        pinned = value
        onPinnedChanged?(value)
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            self.scheduled = false
            guard self.pinned, let adj = self.scroll.vadjustment else { return }
            self.autoScrolling = true
            adj.value = adj.upper - adj.pageSize
            self.autoScrolling = false
        }
    }
}
