import Adw
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

@MainActor
final class ChatColumnsPane {
    let widget = Overlay()
    let chatID: UUID

    private let columns: PharoColumnsView

    init(engine: Engine, chatID: UUID) {
        self.chatID = chatID
        widget.hexpand = true
        widget.vexpand = true
        columns = PharoColumnsView(engine: engine, runtime: PharoRuntime.shared, maximizingOver: widget, highlight: PharoHighlighting.apply)
        widget.set(child: columns.widget)
        Task { @MainActor in
            do {
                columns.present(try await engine.objectChats.column(of: chatID))
            } catch {
                let page = Adw.StatusPage()
                page.iconName = "chat-message-new-symbolic"
                page.title = "This chat could not be opened"
                page.description = error.localizedDescription
                widget.set(child: page)
            }
        }
    }
}
