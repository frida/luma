import CGtk
import CLuma
import Gtk
import LumaCore

@MainActor
final class VirtualMachineLog {
    let widget: ScrolledWindow
    let console: VirtualMachineConsole

    private let view: TextView
    private let scroller: BottomScroller
    private var shownFirstLineNumber = 0
    private var shownEndLineNumber = 0

    init(console: VirtualMachineConsole) {
        self.console = console

        view = TextView()
        view.editable = false
        view.cursorVisible = false
        view.wrapMode = .wordChar
        view.topMargin = 6
        view.bottomMargin = 6
        view.leftMargin = 6
        view.rightMargin = 6
        view.add(cssClass: "monospace")
        view.add(cssClass: "luma-machine-log")
        _ = luma_text_buffer_create_style_tag(view.buffer.ptr, Self.alarmTag, Self.alarmColor, false, false)

        widget = ScrolledWindow()
        widget.hexpand = true
        widget.vexpand = true
        widget.setSizeRequest(width: -1, height: Self.minimumHeight)
        widget.set(child: view)
        scroller = BottomScroller(widget)

        catchUp()
    }

    func catchUp() {
        removeLinesTheConsoleDropped()
        appendLinesNotYetShown()
    }

    func scrollToBottom() {
        scroller.scrollToBottom()
    }

    private func removeLinesTheConsoleDropped() {
        let droppedCount = min(console.firstLineNumber, shownEndLineNumber) - shownFirstLineNumber
        if droppedCount > 0 {
            let buffer = view.buffer.text_buffer_ptr
            var start = GtkTextIter()
            var end = GtkTextIter()
            gtk_text_buffer_get_start_iter(buffer, &start)
            gtk_text_buffer_get_iter_at_line(buffer, &end, gint(droppedCount))
            gtk_text_buffer_delete(buffer, &start, &end)
        }
        shownFirstLineNumber = console.firstLineNumber
        shownEndLineNumber = max(shownEndLineNumber, shownFirstLineNumber)
    }

    private func appendLinesNotYetShown() {
        let buffer = view.buffer.text_buffer_ptr
        var start = GtkTextIter()
        var end = GtkTextIter()
        for line in console.lines(from: shownEndLineNumber) {
            gtk_text_buffer_get_end_iter(buffer, &end)
            let offset = gtk_text_iter_get_offset(&end)
            gtk_text_buffer_insert(buffer, &end, line.text + "\n", -1)
            guard line.isAlarming else { continue }
            gtk_text_buffer_get_iter_at_offset(buffer, &start, offset)
            gtk_text_buffer_get_end_iter(buffer, &end)
            gtk_text_buffer_apply_tag_by_name(buffer, Self.alarmTag, &start, &end)
        }
        shownEndLineNumber = console.endLineNumber
    }

    private static let alarmTag = "alarm"
    private static let alarmColor = "#e01b24"
    private static let minimumHeight = 240
}
