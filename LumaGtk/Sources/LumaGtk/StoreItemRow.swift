import Foundation
import Gtk
import LumaCore

@MainActor
final class StoreItemRow {
    let row: ListBoxRow
    private(set) var item: StoreItem

    private let alreadyAdded: Bool
    private let nameLabel: Label
    private let bylineLabel: Label
    private let accessLabel: Label
    private let installStateLabel: Label

    init(item: StoreItem, storefront: Storefront, incompatibilityReason: String?, alreadyAdded: Bool) {
        self.item = item
        self.alreadyAdded = alreadyAdded
        row = ListBoxRow()
        let rowBox = Box(orientation: .horizontal, spacing: 8)
        rowBox.marginStart = 12
        rowBox.marginEnd = 12
        rowBox.marginTop = 6
        rowBox.marginBottom = 6
        rowBox.valign = .center

        let icon = InstrumentIconView.makeImage(for: item, from: storefront, pixelSize: 16)
        icon.valign = .start
        rowBox.append(child: icon)

        let titles = Box(orientation: .vertical, spacing: 2)
        titles.hexpand = true
        nameLabel = Label(str: "")
        nameLabel.halign = .start
        nameLabel.ellipsize = .end
        titles.append(child: nameLabel)
        bylineLabel = Label(str: "")
        bylineLabel.halign = .start
        bylineLabel.ellipsize = .end
        bylineLabel.add(cssClass: "caption")
        bylineLabel.add(cssClass: "dim-label")
        titles.append(child: bylineLabel)
        rowBox.append(child: titles)

        if let incompatibilityReason {
            let warning = Gtk.Image(iconName: "dialog-warning-symbolic")
            warning.pixelSize = 12
            warning.valign = .start
            warning.tooltipText = incompatibilityReason
            rowBox.append(child: warning)
        }

        let trailing = Box(orientation: .vertical, spacing: 2)
        trailing.valign = .center
        accessLabel = Label(str: "")
        accessLabel.halign = .end
        accessLabel.add(cssClass: "caption")
        accessLabel.add(cssClass: "dim-label")
        trailing.append(child: accessLabel)
        installStateLabel = Label(str: "")
        installStateLabel.halign = .end
        installStateLabel.add(cssClass: "caption-heading")
        trailing.append(child: installStateLabel)
        rowBox.append(child: trailing)

        row.set(child: rowBox)

        if alreadyAdded {
            row.sensitive = false
            row.selectable = false
        }
        show(item, installState: storefront.installState(of: item))
    }

    func show(_ item: StoreItem, installState: Storefront.InstallState) {
        self.item = item
        nameLabel.label = item.name
        bylineLabel.label = alreadyAdded ? "Already added" : item.publisher.name
        accessLabel.label = accessText(item.access)
        showInstallState(installState)
    }

    private func accessText(_ access: StoreAccess) -> String {
        switch access {
        case .free:
            return "Free"
        case .sponsor(let minimumMonthlyCents):
            return "From \(StorePrice.monthly(cents: minimumMonthlyCents))"
        }
    }

    private func showInstallState(_ installState: Storefront.InstallState) {
        switch installState {
        case .notInstalled:
            installStateLabel.visible = false
        case .requiresLuma(let version):
            installStateLabel.label = "Requires Luma \(version)"
            installStateLabel.remove(cssClass: "accent")
            installStateLabel.add(cssClass: "dim-label")
            installStateLabel.visible = true
        case .installed:
            installStateLabel.label = "Installed"
            installStateLabel.remove(cssClass: "accent")
            installStateLabel.add(cssClass: "dim-label")
            installStateLabel.visible = true
        case .updateAvailable:
            installStateLabel.label = "Update"
            installStateLabel.remove(cssClass: "dim-label")
            installStateLabel.add(cssClass: "accent")
            installStateLabel.visible = true
        }
    }
}
