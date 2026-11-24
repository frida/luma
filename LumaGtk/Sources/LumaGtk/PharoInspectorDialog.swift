import Adw
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

@MainActor
final class PharoInspectorDialog {
    private static var presented: PharoInspectorDialog?

    private let engine: Engine
    private let dialog = Adw.Dialog()
    private let content = Box(orientation: .vertical, spacing: 0)
    private let columns: PharoColumnsView

    static func present(engine: Engine, parent: Widget, opening object: @escaping () async throws -> PharoObject) {
        let presented = PharoInspectorDialog(engine: engine)
        Self.presented = presented
        presented.dialog.present(parent: parent)
        presented.open(object)
    }

    private init(engine: Engine) {
        self.engine = engine

        let overlay = Overlay()
        overlay.hexpand = true
        overlay.vexpand = true
        columns = PharoColumnsView(
            engine: engine, runtime: PharoRuntime.shared, maximizingOver: overlay, highlight: PharoHighlighting.apply)
        overlay.set(child: columns.widget)
        content.append(child: overlay)

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: Adw.HeaderBar())
        toolbarView.set(content: content)

        dialog.set(contentWidth: 860)
        dialog.set(contentHeight: 600)
        dialog.set(child: toolbarView)
        dialog.onClosed { _ in
            MainActor.assumeIsolated { Self.presented = nil }
        }
        columns.onChanged = { [weak self] in
            guard let self, self.columns.isEmpty else { return }
            _ = self.dialog.close()
        }
    }

    private func open(_ object: @escaping () async throws -> PharoObject) {
        Task { @MainActor in
            do {
                try await PharoRuntime.shared.startPlayground(for: engine)
                columns.present(try await object())
            } catch {
                content.prepend(child: PharoViewPages.failurePage(error.localizedDescription))
            }
        }
    }
}
