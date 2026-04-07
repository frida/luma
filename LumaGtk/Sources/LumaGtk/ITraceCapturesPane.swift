import Foundation
import Gtk
import LumaCore

@MainActor
final class ITraceCapturesPane {
    let widget: Box

    private let engine: Engine
    private let sessionID: UUID
    private let listBox: ListBox
    private let detailContainer: Box
    private var captures: [ITraceCaptureRecord] = []
    private var currentDetail: ITraceDetailView?
    private let dateFormatter: DateFormatter

    init(engine: Engine, sessionID: UUID) {
        self.engine = engine
        self.sessionID = sessionID

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        self.dateFormatter = formatter

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")

        detailContainer = Box(orientation: .vertical, spacing: 0)
        detailContainer.hexpand = true
        detailContainer.vexpand = true

        captures = (try? engine.store.fetchITraceCaptures(sessionID: sessionID)) ?? []

        if captures.isEmpty {
            let empty = MainWindow.makeEmptyState(
                icon: "media-playback-start-symbolic",
                title: "No ITrace captures yet",
                subtitle: "Capture-based recordings appear here as your hooks fire."
            )
            widget.append(child: empty)
            return
        }

        for capture in captures {
            let row = ListBoxRow()
            let label = Label(
                str: "\(capture.displayName) · \(dateFormatter.string(from: capture.capturedAt))"
            )
            label.halign = .start
            label.marginStart = 12
            label.marginEnd = 12
            label.marginTop = 6
            label.marginBottom = 6
            row.set(child: label)
            listBox.append(child: row)
        }

        listBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                let index = Int(row.index)
                self.showCapture(at: index)
            }
        }

        let listScroll = ScrolledWindow()
        listScroll.hexpand = false
        listScroll.vexpand = true
        listScroll.set(child: listBox)
        listScroll.setSizeRequest(width: 280, height: -1)

        let placeholder = Label(str: "Select a capture to view its trace.")
        placeholder.halign = .center
        placeholder.valign = .center
        placeholder.hexpand = true
        placeholder.vexpand = true
        placeholder.add(cssClass: "dim-label")
        detailContainer.append(child: placeholder)

        let paned = Paned(orientation: .horizontal)
        paned.position = 280
        paned.startChild = WidgetRef(listScroll)
        paned.endChild = WidgetRef(detailContainer)
        paned.hexpand = true
        paned.vexpand = true
        widget.append(child: paned)
    }

    private func showCapture(at index: Int) {
        guard index >= 0, index < captures.count else { return }
        var child = detailContainer.firstChild
        while let current = child {
            child = current.nextSibling
            detailContainer.remove(child: current)
        }
        let others = captures.enumerated().compactMap { $0.offset == index ? nil : $0.element }
        let detail = ITraceDetailView(
            capture: captures[index],
            otherCaptures: others,
            engine: engine,
            sessionID: sessionID
        )
        currentDetail = detail
        detailContainer.append(child: detail.widget)
    }
}
