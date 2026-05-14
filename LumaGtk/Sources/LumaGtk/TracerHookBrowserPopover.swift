import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class TracerHookBrowserPopover {
    private static var active: TracerHookBrowserPopover?

    private enum Entry {
        case sectionHeader(String)
        case hook(TracerConfig.Hook)
    }

    private let hooks: [TracerConfig.Hook]
    private let onChoose: (TracerConfig.Hook) -> Void

    private var popover: Popover?
    private var listBox: ListBox?
    private var entries: [Entry] = []
    private var query: String = ""

    init(hooks: [TracerConfig.Hook], onChoose: @escaping (TracerConfig.Hook) -> Void) {
        self.hooks = hooks
        self.onChoose = onChoose
    }

    func presentAnchored(to anchor: WidgetProtocol) {
        TracerHookBrowserPopover.active = self
        let popover = Popover()
        popover.autohide = true
        popover.position = .right
        popover.onClosed { _ in
            MainActor.assumeIsolated {
                TracerHookBrowserPopover.active = nil
            }
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
        popover.install(controller: key)

        let column = Box(orientation: .vertical, spacing: 8)
        column.marginStart = 8
        column.marginEnd = 8
        column.marginTop = 8
        column.marginBottom = 8
        column.setSizeRequest(width: 320, height: 380)

        let searchEntry = SearchEntry()
        searchEntry.placeholderText = "Filter hooks"
        searchEntry.hexpand = true
        searchEntry.onSearchChanged { [weak self] entry in
            MainActor.assumeIsolated {
                self?.query = entry.text
                self?.refreshList()
            }
        }
        searchEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated {
                self?.chooseFirstMatch()
            }
        }
        column.append(child: searchEntry)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.hasFrame = false

        let listBox = ListBox()
        listBox.selectionMode = .none
        listBox.add(cssClass: "navigation-sidebar")
        listBox.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                let index = Int(row.index)
                guard index >= 0, index < self.entries.count else { return }
                if case .hook(let hook) = self.entries[index] {
                    self.choose(hook)
                }
            }
        }
        scroll.set(child: listBox)
        column.append(child: scroll)

        popover.set(child: column)
        popover.set(parent: WidgetRef(anchor))

        self.popover = popover
        self.listBox = listBox

        refreshList()
        popover.popup()
        _ = searchEntry.grabFocus()
    }

    private func refreshList() {
        guard let listBox else { return }
        let matching = filteredHooks()

        while let child = listBox.firstChild {
            listBox.remove(child: child)
        }

        entries = []
        var previousModule: String?
        for hook in matching {
            let module = hook.addressAnchor.moduleGroupName
            if module != previousModule {
                entries.append(.sectionHeader(module))
                listBox.append(child: makeSectionHeaderRow(name: module))
                previousModule = module
            }
            entries.append(.hook(hook))
            listBox.append(child: makeHookRow(hook: hook))
        }

        if matching.isEmpty {
            let emptyRow = ListBoxRow()
            emptyRow.selectable = false
            let label = Label(str: "No matching hooks")
            label.halign = .start
            label.marginStart = 12
            label.marginEnd = 12
            label.marginTop = 6
            label.marginBottom = 6
            label.add(cssClass: "dim-label")
            emptyRow.set(child: label)
            listBox.append(child: emptyRow)
        }
    }

    private func makeSectionHeaderRow(name: String) -> ListBoxRow {
        let row = ListBoxRow()
        row.selectable = false
        row.activatable = false
        row.canFocus = false
        let label = Label(str: name)
        label.halign = .start
        label.add(cssClass: "caption-heading")
        label.add(cssClass: "dim-label")
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 6
        label.marginBottom = 2
        row.set(child: label)
        return row
    }

    private func filteredHooks() -> [TracerConfig.Hook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return hooks }
        return hooks.filter { hook in
            hook.displayName.localizedCaseInsensitiveContains(trimmed)
                || hook.addressAnchor.moduleGroupName.localizedCaseInsensitiveContains(trimmed)
                || hook.addressAnchor.displayString.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func makeHookRow(hook: TracerConfig.Hook) -> ListBoxRow {
        let row = ListBoxRow()
        let box = Box(orientation: .horizontal, spacing: 6)
        box.marginStart = 12
        box.marginEnd = 12
        box.marginTop = 4
        box.marginBottom = 4
        let label = Label(str: hook.displayName)
        label.halign = .start
        label.hexpand = true
        label.ellipsize = .end
        box.append(child: label)
        if hook.state == .disabled {
            box.opacity = 0.5
        }
        box.tooltipText = hook.addressAnchor.displayString
        row.set(child: box)
        return row
    }

    private func chooseFirstMatch() {
        for entry in entries {
            if case .hook(let hook) = entry {
                choose(hook)
                return
            }
        }
    }

    private func choose(_ hook: TracerConfig.Hook) {
        dismiss()
        onChoose(hook)
    }

    private func dismiss() {
        guard let popover else { return }
        popover.popdown()
        popover.unparent()
        self.popover = nil
        listBox = nil
    }
}
