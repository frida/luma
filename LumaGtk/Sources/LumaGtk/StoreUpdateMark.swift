import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class StoreUpdateMark {
    let widget: Gtk.Image

    private let storefront: Storefront
    private let defID: UUID

    init(storefront: Storefront, defID: UUID) {
        self.storefront = storefront
        self.defID = defID

        widget = Gtk.Image(iconName: "software-update-available-symbolic")
        widget.pixelSize = 12
        widget.valign = .center
        widget.add(cssClass: "accent")
        widget.visible = false

        observe()
    }

    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
            }
        }
    }

    private func render() {
        guard case .newer(let item) = storefront.linkedInstallation(ofCustomInstrument: defID)?.latest else {
            widget.visible = false
            return
        }
        widget.tooltipText = "Version \(item.version) is available"
        widget.visible = true
    }
}
