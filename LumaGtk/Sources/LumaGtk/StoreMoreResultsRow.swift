import Foundation
import Gtk
import LumaCore

@MainActor
final class StoreMoreResultsRow {
    let row: ListBoxRow

    private let titleLabel: Label
    private let remainingLabel: Label
    private let spinner: Spinner
    private let retryButton: Button

    init(onLoadMore: @escaping () -> Void) {
        row = ListBoxRow()
        row.selectable = false

        let rowBox = Box(orientation: .horizontal, spacing: 8)
        rowBox.marginStart = 12
        rowBox.marginEnd = 12
        rowBox.marginTop = 6
        rowBox.marginBottom = 6
        rowBox.valign = .center

        titleLabel = Label(str: "")
        titleLabel.halign = .start
        titleLabel.hexpand = true
        titleLabel.xalign = 0
        rowBox.append(child: titleLabel)

        remainingLabel = Label(str: "")
        remainingLabel.add(cssClass: "caption")
        remainingLabel.add(cssClass: "dim-label")
        rowBox.append(child: remainingLabel)

        spinner = makeSpinner()
        rowBox.append(child: spinner)

        retryButton = Button(label: "Retry")
        retryButton.add(cssClass: "flat")
        retryButton.valign = .center
        retryButton.onClicked { _ in
            MainActor.assumeIsolated { onLoadMore() }
        }
        rowBox.append(child: retryButton)

        row.set(child: rowBox)
    }

    func show(_ moreResults: Storefront.MoreResults, remaining: Int) {
        switch moreResults {
        case .allLoaded, .available:
            showAvailable(remaining: remaining)
        case .loading:
            showLoading()
        case .failed(let message):
            showFailure(message: message)
        }
    }

    private func showAvailable(remaining: Int) {
        row.activatable = true
        row.tooltipText = nil
        titleLabel.label = "Show More"
        titleLabel.remove(cssClass: "dim-label")
        remainingLabel.label = "\(remaining.formatted()) more"
        remainingLabel.visible = true
        spinner.visible = false
        retryButton.visible = false
    }

    private func showLoading() {
        row.activatable = false
        row.tooltipText = nil
        titleLabel.label = "Show More"
        titleLabel.add(cssClass: "dim-label")
        remainingLabel.visible = false
        spinner.visible = true
        retryButton.visible = false
    }

    private func showFailure(message: String) {
        row.activatable = false
        row.tooltipText = message
        titleLabel.label = "Could not load more."
        titleLabel.add(cssClass: "dim-label")
        remainingLabel.visible = false
        spinner.visible = false
        retryButton.visible = true
    }
}
