import Adw
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

@MainActor
final class ChatColumnsPane {
    let widget = Box(orientation: .vertical, spacing: 0)
    let chatID: UUID

    private let overviewBar = PharoOverviewBar()
    private let overviewSeparator = Separator(orientation: .horizontal)
    private let overlay = Overlay()
    private let page = Box(orientation: .vertical, spacing: 0)
    private let columns: PharoColumnsView
    private var chatColumn: PharoColumnView?

    private static let pageWidth = 440

    init(engine: Engine, chatID: UUID) {
        self.chatID = chatID
        widget.hexpand = true
        widget.vexpand = true
        overlay.vexpand = true
        page.vexpand = true

        columns = PharoColumnsView(engine: engine, runtime: PharoRuntime.shared, maximizingOver: overlay, highlight: PharoHighlighting.apply)
        columns.widget.visible = false

        let paned = Paned(orientation: .horizontal)
        paned.resizeStartChild = false
        paned.resizeEndChild = true
        paned.shrinkStartChild = false
        paned.shrinkEndChild = false
        paned.position = Self.pageWidth
        paned.startChild = WidgetRef(page)
        paned.endChild = WidgetRef(columns.widget)
        overlay.set(child: paned)

        overviewBar.widget.visible = false
        overviewSeparator.visible = false
        widget.append(child: overviewBar.widget)
        widget.append(child: overviewSeparator)
        widget.append(child: overlay)

        let chats = engine.objectChats
        columns.drive(overviewBar) { chats.chat(withID: chatID).map(chats.displayTitle(of:)) ?? "Project Chat" }
        columns.onChanged = { [weak self] in
            guard let self else { return }
            let isDrilling = !self.columns.isEmpty
            self.columns.widget.visible = isDrilling
            self.overviewBar.widget.visible = isDrilling
            self.overviewSeparator.visible = isDrilling
            self.overviewBar.reload()
        }

        Task { @MainActor in
            do {
                show(try await chats.column(of: chatID), engine: engine)
            } catch {
                let status = Adw.StatusPage()
                status.iconName = "chat-message-new-symbolic"
                status.title = "This chat could not be opened"
                status.description = error.localizedDescription
                status.vexpand = true
                page.append(child: status)
            }
        }
    }

    private func show(_ object: PharoObject, engine: Engine) {
        let view = PharoColumnView(engine: engine, runtime: PharoRuntime.shared, object: object, isMaximized: false, highlight: PharoHighlighting.apply)
        view.offersLayoutActions = false
        view.onDrill = { [weak self] element in self?.columns.present(element) }
        view.onClose = { [weak self] in
            guard let self, let chatColumn = self.chatColumn else { return }
            self.page.remove(child: chatColumn.widget)
            self.chatColumn = nil
            self.columns.clearAll()
        }
        chatColumn = view
        page.append(child: view.widget)
    }
}
