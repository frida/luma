import Gtk

extension WidgetProtocol {
    /// Clears the toplevel window's focus **only** when the focused widget lives
    /// inside this subtree — i.e. only when this subtree is about to be rebuilt
    /// or removed.
    ///
    /// Clearing focus unconditionally (setting `root.focus = nil`) steals focus
    /// from unrelated widgets. The REPL input, for example, sits outside the
    /// sidebar/detached-badge subtrees that get refreshed on every engine state
    /// update, so a blanket clear makes the entry lose focus mid-typing.
    func clearFocusIfInside() {
        guard let root = self.root else { return }
        guard let focused = root.focus else { return }
        if focused.widget_ptr == self.widget_ptr || focused.is_(ancestor: self) {
            root.focus = nil
        }
    }
}
