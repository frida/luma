import Foundation
import Gtk
import LumaCore

@MainActor
final class StoreSectionHeaderRow {
    let row: ListBoxRow

    private let rowBox: Box
    private let reloadSpinner: Spinner
    private let onChooseCategory: (StoreCategory.ID?) -> Void
    private var categoryFilter: CategoryFilter?

    private struct CategoryFilter {
        let offered: [StoreCategory]
        let dropdown: DropDown
    }

    init(onChooseCategory: @escaping (StoreCategory.ID?) -> Void) {
        self.onChooseCategory = onChooseCategory
        row = ListBoxRow()
        row.selectable = false
        row.activatable = false
        row.focusable = false

        rowBox = Box(orientation: .horizontal, spacing: 6)
        rowBox.marginStart = 12
        rowBox.marginEnd = 6
        rowBox.marginTop = 14
        rowBox.marginBottom = 4

        let title = Label(str: "Store")
        title.halign = .start
        title.valign = .center
        title.hexpand = true
        title.add(cssClass: "caption-heading")
        title.add(cssClass: "dim-label")
        rowBox.append(child: title)

        reloadSpinner = makeSpinner()
        reloadSpinner.valign = .center
        reloadSpinner.visible = false
        rowBox.append(child: reloadSpinner)

        row.set(child: rowBox)
    }

    func showReloading(_ isReloading: Bool) {
        reloadSpinner.visible = isReloading
    }

    func showCategoryFilter(offering categories: [StoreCategory], selected: StoreCategory.ID?) {
        guard categoryFilter?.offered != categories else { return }
        hideCategoryFilter()
        let dropdown = makeCategoryDropdown(offering: categories, selected: selected)
        rowBox.append(child: dropdown)
        categoryFilter = CategoryFilter(offered: categories, dropdown: dropdown)
    }

    func hideCategoryFilter() {
        guard let categoryFilter else { return }
        rowBox.remove(child: categoryFilter.dropdown)
        self.categoryFilter = nil
    }

    private func makeCategoryDropdown(offering categories: [StoreCategory], selected: StoreCategory.ID?) -> DropDown {
        let choices: [StoreCategory.ID?] = [nil] + categories.map(\.id)
        let dropdown = DropDown.listing(["All Categories"] + categories.map(\.name))
        dropdown.add(cssClass: "flat")
        dropdown.valign = .center
        dropdown.selected = choices.firstIndex(of: selected) ?? 0
        let onChooseCategory = self.onChooseCategory
        dropdown.onNotifySelected { dropdown, _ in
            MainActor.assumeIsolated { onChooseCategory(choices[Int(dropdown.selected)]) }
        }
        return dropdown
    }
}
