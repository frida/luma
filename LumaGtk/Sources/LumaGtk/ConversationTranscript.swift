import CGtk
import Gtk

@MainActor
final class ConversationTranscript {
    let widget: ScrolledWindow

    private let list: Box
    private var scrollsWhenSized = false

    init() {
        widget = ScrolledWindow()
        widget.hexpand = true
        widget.vexpand = true
        widget.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)

        list = Box(orientation: .vertical, spacing: 8)
        list.marginStart = 12
        list.marginEnd = 12
        list.marginTop = 12
        list.marginBottom = 12
        list.valign = .end
        widget.set(child: list)

        widget.vadjustment?.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scrollsWhenSized, self.list.width > 0 else { return }
                self.scrollsWhenSized = false
                self.scrollToBottom()
            }
        }
    }

    func append(_ row: Widget) {
        list.append(child: row)
    }

    func remove(_ row: Widget) {
        list.remove(child: row)
    }

    func scrollToBottom() {
        Task { @MainActor [weak self] in
            guard let self, let adj = self.widget.vadjustment else { return }
            guard self.list.width > 0 else {
                self.scrollsWhenSized = true
                return
            }
            var natural: gint = 0
            self.list.measure(orientation: .vertical, for: Int(self.list.width), natural: &natural)
            adj.upper = Double(natural)
            adj.value = max(0, adj.upper - adj.pageSize)
        }
    }
}
