import CGtk
import Foundation
import Gdk
import Gtk

@MainActor
final class SidebarBrowserPopover<Item> {
    private let items: [Item]
    private let placeholder: String
    private let emptyMessage: String
    private let groupName: (Item) -> String
    private let title: (Item) -> String
    private let tooltip: (Item) -> String?
    private let dimmed: (Item) -> Bool
    private let matches: (Item, String) -> Bool
    private let onChoose: (Item) -> Void

    private var retainer: SidebarBrowserPopover?
    private var popover: Popover?
    private var rowModel: StringList?
    private var emptyLabel: Label?
    private var rowViews: [UnsafeMutableRawPointer: RowView] = [:]
    private var visibleItems: [Item] = []
    private var query: String = ""

    private final class RowView {
        let box: Box
        let headerLabel: Label
        let titleLabel: Label

        init(box: Box, headerLabel: Label, titleLabel: Label) {
            self.box = box
            self.headerLabel = headerLabel
            self.titleLabel = titleLabel
        }
    }

    init(
        items: [Item],
        placeholder: String,
        emptyMessage: String,
        groupName: @escaping (Item) -> String,
        title: @escaping (Item) -> String,
        tooltip: @escaping (Item) -> String? = { _ in nil },
        dimmed: @escaping (Item) -> Bool = { _ in false },
        matches: @escaping (Item, String) -> Bool,
        onChoose: @escaping (Item) -> Void
    ) {
        self.items = items
        self.placeholder = placeholder
        self.emptyMessage = emptyMessage
        self.groupName = groupName
        self.title = title
        self.tooltip = tooltip
        self.dimmed = dimmed
        self.matches = matches
        self.onChoose = onChoose
    }

    func presentAnchored(to anchor: WidgetProtocol) {
        retainer = self
        // Pop up after the list-row signal that triggered us finishes emitting;
        // grabbing and reparenting mid-emission faults inside GTK.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.buildAndPresent(anchoredTo: anchor)
        }
    }

    private func buildAndPresent(anchoredTo anchor: WidgetProtocol) {
        let popover = Popover()
        popover.autohide = true
        popover.position = .right
        popover.onClosed { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanup() }
        }

        let key = EventControllerKey()
        key.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                if Int32(keyval) == Gdk.keyEscape {
                    self?.dismiss()
                    return true
                }
                return false
            }
        }
        popover.add(controller: key)

        let column = Box(orientation: .vertical, spacing: 8)
        column.marginStart = 8
        column.marginEnd = 8
        column.marginTop = 8
        column.marginBottom = 8
        column.setSizeRequest(width: 320, height: 380)

        let searchEntry = SearchEntry()
        searchEntry.placeholderText = placeholder
        searchEntry.hexpand = true
        searchEntry.onSearchChanged { [weak self] entry in
            MainActor.assumeIsolated {
                self?.query = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.refreshRows()
            }
        }
        searchEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.chooseFirstMatch() }
        }
        searchEntry.onStopSearch { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        column.append(child: searchEntry)

        let rowModel = StringList(strings: nil)
        let selection = NoSelection(model: rowModel)
        let factory = SignalListItemFactory()
        let listView = ListView(model: selection, factory: factory)
        _ = g_object_ref(rowModel.ptr)
        _ = g_object_ref(selection.ptr)
        listView.singleClickActivate = true
        listView.add(cssClass: "navigation-sidebar")
        listView.onActivate { [weak self] _, position in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.choose(self.visibleItems[Int(position)])
            }
        }
        configure(factory)

        let emptyLabel = makeEmptyLabel()
        column.append(child: emptyLabel)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.hasFrame = false
        scroll.set(child: listView)
        column.append(child: scroll)

        popover.set(child: column)
        popover.set(parent: WidgetRef(anchor))

        self.popover = popover
        self.rowModel = rowModel
        self.emptyLabel = emptyLabel

        refreshRows()

        popover.popup()
        _ = searchEntry.grabFocus()
    }

    private func configure(_ factory: SignalListItemFactory) {
        factory.onSetup { [weak self] _, object in
            MainActor.assumeIsolated {
                guard let self else { return }
                let rowView = self.makeRowView()
                self.rowViews[rowView.box.ptr] = rowView
                ListItemRef(raw: object.ptr).set(child: rowView.box)
            }
        }
        factory.onBind { [weak self] _, object in
            MainActor.assumeIsolated {
                guard let self else { return }
                let item = ListItemRef(raw: object.ptr)
                guard let child = item.child, let rowView = self.rowViews[child.ptr] else { return }
                self.bind(rowView, to: item.position)
            }
        }
        factory.onTeardown { [weak self] _, object in
            MainActor.assumeIsolated {
                guard let self, let child = ListItemRef(raw: object.ptr).child else { return }
                self.rowViews.removeValue(forKey: child.ptr)
            }
        }
    }

    private func refreshRows() {
        visibleItems = items.filter(isVisible)
        emptyLabel?.visible = visibleItems.isEmpty
        replaceRows(count: visibleItems.count)
    }

    private func replaceRows(count: Int) {
        guard let rowModel else { return }
        "".withCString { blank in
            let additions = [UnsafePointer<CChar>?](repeating: blank, count: count) + [nil]
            additions.withUnsafeBufferPointer {
                rowModel.splice(position: 0, nRemovals: rowModel.nItems, additions: $0.baseAddress)
            }
        }
    }

    private func bind(_ rowView: RowView, to position: Int) {
        let item = visibleItems[position]
        let group = groupName(item)
        rowView.headerLabel.setText(str: group)
        rowView.headerLabel.visible = position == 0 || groupName(visibleItems[position - 1]) != group
        rowView.titleLabel.setText(str: title(item))
        rowView.titleLabel.opacity = dimmed(item) ? 0.5 : 1
        rowView.box.tooltipText = tooltip(item)
    }

    private func isVisible(_ item: Item) -> Bool {
        query.isEmpty || matches(item, query)
    }

    private func chooseFirstMatch() {
        guard let item = visibleItems.first else { return }
        choose(item)
    }

    private func choose(_ item: Item) {
        dismiss()
        onChoose(item)
    }

    private func dismiss() {
        popover?.popdown()
        cleanup()
    }

    private func cleanup() {
        popover?.unparent()
        popover = nil
        rowModel = nil
        emptyLabel = nil
        retainer = nil
    }

    private func makeRowView() -> RowView {
        let headerLabel = makeSectionHeader()

        let titleLabel = Label(str: "")
        titleLabel.halign = .start
        titleLabel.hexpand = true
        titleLabel.ellipsize = .end
        titleLabel.marginStart = 12
        titleLabel.marginEnd = 12
        titleLabel.marginTop = 4
        titleLabel.marginBottom = 4

        let box = Box(orientation: .vertical, spacing: 0)
        box.append(child: headerLabel)
        box.append(child: titleLabel)
        return RowView(box: box, headerLabel: headerLabel, titleLabel: titleLabel)
    }

    private func makeSectionHeader() -> Label {
        let label = Label(str: "")
        label.halign = .start
        label.add(cssClass: "caption-heading")
        label.add(cssClass: "dim-label")
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 6
        label.marginBottom = 2
        return label
    }

    private func makeEmptyLabel() -> Label {
        let label = Label(str: emptyMessage)
        label.halign = .start
        label.add(cssClass: "dim-label")
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 6
        label.marginBottom = 6
        return label
    }
}
