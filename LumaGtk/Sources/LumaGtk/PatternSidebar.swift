import Adw
import Foundation
import Frida
import Gtk
import LumaCore
import Observation

enum PatternSidebarSelection: Equatable {
    case library
    case source(String)
    case type(sourceID: String, name: String)

    var sourceID: String? {
        switch self {
        case .library:
            return nil
        case .source(let id), .type(let id, _):
            return id
        }
    }

    var typeName: String? {
        if case .type(_, let name) = self { name } else { nil }
    }
}

@MainActor
final class PatternSidebar {
    let widget: ListBox
    var onSelect: (PatternSidebarSelection) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }

    private let engine: Engine
    private let window: Gtk.Window
    private var rows: [Row] = []
    private var outlines: [String: [PatternTypeSummary]] = [:]
    private var expandedSources: Set<String> = []
    private var isExpanded = true
    private var selection: PatternSidebarSelection?
    private var isSelectingProgrammatically = false

    private static let chevronColumnWidth = 24
    private static let chevronToIconSpacing = 5

    private enum Row: Equatable {
        case header
        case source(String)
        case type(sourceID: String, name: String)
        case browseAll(sourceID: String)
    }

    init(engine: Engine, window: Gtk.Window) {
        self.engine = engine
        self.window = window
        widget = ListBox()
        widget.selectionMode = .single
        widget.add(cssClass: "navigation-sidebar")
        widget.add(cssClass: "luma-flush-sidebar-list")
        widget.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, !self.isSelectingProgrammatically, let row else { return }
                self.choose(rowAt: Int(row.index), anchor: row)
            }
        }
        widget.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                self?.choose(rowAt: Int(row.index), anchor: row)
            }
        }
        render()
        observeSources()
        outline()
    }

    func select(_ newSelection: PatternSidebarSelection) {
        selection = newSelection
        if let sourceID = newSelection.sourceID {
            isExpanded = true
            expandedSources.insert(sourceID)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.visibleRows() == self.rows {
                self.syncSelection()
            } else {
                self.render()
            }
        }
    }

    func unselectAll() {
        selection = nil
        widget.unselectAll()
    }

    private func choose(rowAt index: Int, anchor: ListBoxRowRef) {
        switch rows[index] {
        case .header:
            onSelect(.library)
        case .source(let id):
            onSelect(.source(id))
        case .type(let sourceID, let name):
            onSelect(.type(sourceID: sourceID, name: name))
        case .browseAll(let sourceID):
            presentTypeBrowser(sourceID: sourceID, anchor: anchor)
        }
    }

    private func presentTypeBrowser(sourceID: String, anchor: ListBoxRowRef) {
        SidebarBrowserPopover(
            items: outlines[sourceID] ?? [],
            placeholder: "Filter types",
            emptyMessage: "No matching types",
            groupName: { $0.kind.title },
            title: { $0.name },
            tooltip: { $0.kind.title },
            matches: { type, query in type.name.localizedCaseInsensitiveContains(query) },
            onChoose: { [weak self] type in
                self?.onSelect(.type(sourceID: sourceID, name: type.name))
            }
        ).presentAnchored(to: anchor)
    }

    private func render() {
        rows = visibleRows()
        while let child = widget.firstChild {
            widget.remove(child: child)
        }
        let sourceCount = engine.patterns.sources.count
        for row in rows {
            widget.append(child: makeRow(row, sourceCount: sourceCount))
        }
        syncSelection()
    }

    private func visibleRows() -> [Row] {
        [.header] + (isExpanded ? engine.patterns.sources.flatMap(rows(of:)) : [])
    }

    private func rows(of source: PatternSource) -> [Row] {
        guard expandedSources.contains(source.id) else { return [.source(source.id)] }
        let types = outlines[source.id] ?? []
        let highlights = types.sidebarHighlights(selectedID: selectedTypeName(in: source.id))
        let typeRows = highlights.map { Row.type(sourceID: source.id, name: $0.name) }
        let browseAll = types.count > highlights.count ? [Row.browseAll(sourceID: source.id)] : []
        return [.source(source.id)] + typeRows + browseAll
    }

    private func selectedTypeName(in sourceID: String) -> String? {
        guard case .type(let id, let name) = selection, id == sourceID else { return nil }
        return name
    }

    private func syncSelection() {
        let selectedRow: Row?
        switch selection {
        case .library:
            selectedRow = .header
        case .source(let id):
            selectedRow = .source(id)
        case .type(let sourceID, let name):
            selectedRow = .type(sourceID: sourceID, name: name)
        case nil:
            selectedRow = nil
        }
        isSelectingProgrammatically = true
        if let selectedRow, let index = rows.firstIndex(of: selectedRow), let row = widget.getRowAt(index: index) {
            widget.select(row: row)
        } else {
            widget.unselectAll()
        }
        isSelectingProgrammatically = false
    }

    private func makeRow(_ row: Row, sourceCount: Int) -> ListBoxRow {
        switch row {
        case .header:
            return makeHeaderRow(sourceCount: sourceCount)
        case .source(let id):
            return makeSourceRow(engine.patterns.source(withID: id)!)
        case .type(let sourceID, let name):
            let type = outlines[sourceID]!.first { $0.name == name }!
            let icon = Gtk.Image(iconName: type.kind.iconName)
            icon.pixelSize = 12
            icon.hexpand = true
            icon.halign = .center
            return SidebarFeatureRow.make(icon: icon, title: type.name, tooltip: type.kind.title).row
        case .browseAll(let sourceID):
            return SidebarFeatureRow.makeBrowseAll(totalCount: outlines[sourceID]!.count).row
        }
    }

    private func makeHeaderRow(sourceCount: Int) -> ListBoxRow {
        let box = Box(orientation: .horizontal, spacing: 8)
        box.marginStart = 12
        box.marginEnd = 6
        box.marginTop = 6
        box.marginBottom = 6

        let icon = Gtk.Image(iconName: "view-grid-symbolic")
        icon.pixelSize = 16
        icon.add(cssClass: "accent")
        box.append(child: icon)

        let label = Label(str: "Patterns")
        label.halign = .start
        label.hexpand = true
        box.append(child: label)

        if sourceCount > 0 {
            let count = Label(str: "\(sourceCount)")
            count.add(cssClass: "dim-label")
            count.add(cssClass: "caption")
            box.append(child: count)

            let chevronImage = Gtk.Image(iconName: isExpanded ? "pan-down-symbolic" : "pan-end-symbolic")
            chevronImage.pixelSize = 12
            chevronImage.add(cssClass: "dim-label")
            let chevron = Button()
            chevron.set(child: chevronImage)
            chevron.add(cssClass: "flat")
            chevron.add(cssClass: "circular")
            chevron.tooltipText = isExpanded ? "Hide patterns" : "Show patterns"
            chevron.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isExpanded.toggle()
                    self.render()
                }
            }
            box.append(child: chevron)
        }

        let row = ListBoxRow()
        row.set(child: box)
        return row
    }

    private func makeSourceRow(_ source: PatternSource) -> ListBoxRow {
        let box = Box(orientation: .horizontal, spacing: 0)
        box.halign = .start
        box.marginStart = MainWindow.sessionChildMarginStart - Self.chevronColumnWidth - Self.chevronToIconSpacing
        box.marginEnd = 12
        box.marginTop = 2
        box.marginBottom = 2

        let disclosure = makeDisclosure(for: source)
        disclosure.setSizeRequest(width: Self.chevronColumnWidth, height: -1)
        disclosure.marginEnd = Self.chevronToIconSpacing
        box.append(child: disclosure)

        let icon = Gtk.Image(iconName: source.iconName)
        icon.pixelSize = 16
        icon.add(cssClass: "dim-label")
        icon.setSizeRequest(width: 16, height: -1)
        icon.marginEnd = 6
        box.append(child: icon)

        let label = Label(str: source.name)
        label.halign = .start
        label.ellipsize = .end
        box.append(child: label)

        let row = ListBoxRow()
        row.set(child: box)
        attachContextMenu(to: row, source: source)
        return row
    }

    private func makeDisclosure(for source: PatternSource) -> Widget {
        guard outlines[source.id]?.isEmpty == false else {
            return Box(orientation: .horizontal, spacing: 0)
        }
        let isSourceExpanded = expandedSources.contains(source.id)
        let image = Gtk.Image(iconName: isSourceExpanded ? "pan-down-symbolic" : "pan-end-symbolic")
        image.pixelSize = 12
        image.add(cssClass: "dim-label")
        let button = Button()
        button.set(child: image)
        button.add(cssClass: "flat")
        button.add(cssClass: "luma-sidebar-chevron")
        button.valign = .center
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if isSourceExpanded {
                    self.expandedSources.remove(source.id)
                } else {
                    self.expandedSources.insert(source.id)
                }
                self.render()
            }
        }
        return button
    }

    private func attachContextMenu(to row: ListBoxRow, source: PatternSource) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self] gesture, _, x, y in
            MainActor.assumeIsolated {
                guard let self, let anchor = gesture.widget else { return }
                ContextMenu.present(self.contextMenuItems(for: source), at: anchor, x: x, y: y)
            }
        }
        row.add(controller: click)
    }

    private func contextMenuItems(for source: PatternSource) -> [[ContextMenu.Item]] {
        switch source.origin {
        case .project:
            return [
                [.init("Rename…") { [weak self] in self?.presentRename(source) }],
                [.init("Delete", destructive: true) { [weak self] in self?.confirmDelete(source) }],
            ]
        case .package:
            return [[.init("Copy to Project") { [weak self] in self?.copyToProject(source) }]]
        }
    }

    private func copyToProject(_ source: PatternSource) {
        do {
            onSelect(.source(try engine.patterns.copyToProject(source.id).id))
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func presentRename(_ source: PatternSource) {
        let entry = Entry()
        entry.text = source.name
        entry.hexpand = true
        entry.activatesDefault = true
        let dialog = Adw.AlertDialog(heading: "Rename \(source.kind.title)", body: nil)
        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: "rename", label: "_Rename")
        dialog.setResponseAppearance(response: "rename", appearance: .suggested)
        dialog.setDefault(response: "rename")
        dialog.setClose(response: "cancel")
        dialog.setExtra(child: entry)
        dialog.onResponse { [weak self] _, responseID in
            MainActor.assumeIsolated {
                guard let self, responseID == "rename" else { return }
                self.rename(source, to: entry.text)
            }
        }
        dialog.present(parent: window)
    }

    private func rename(_ source: PatternSource, to name: String) {
        do {
            let renamed = try engine.patterns.rename(source.id, to: name)
            switch selection {
            case .source(source.id):
                onSelect(.source(renamed.id))
            case .type(source.id, let typeName):
                onSelect(.type(sourceID: renamed.id, name: typeName))
            default:
                break
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func confirmDelete(_ source: PatternSource) {
        let dialog = Adw.AlertDialog(heading: "Delete \(source.name)?", body: "This removes \(source.fileName) from the project.")
        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: "delete", label: "_Delete")
        dialog.setResponseAppearance(response: "delete", appearance: .destructive)
        dialog.setDefault(response: "cancel")
        dialog.setClose(response: "cancel")
        dialog.onResponse { [weak self] _, responseID in
            MainActor.assumeIsolated {
                guard let self, responseID == "delete" else { return }
                self.delete(source)
            }
        }
        dialog.present(parent: window)
    }

    private func delete(_ source: PatternSource) {
        do {
            try engine.patterns.delete(source.id)
            if selection?.sourceID == source.id {
                onSelect(.library)
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func observeSources() {
        withObservationTracking {
            _ = engine.patterns.sources
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.render()
                self.outline()
                self.observeSources()
            }
        }
    }

    private func outline() {
        let sources = engine.patterns.sources
        Task { @MainActor [weak self] in
            var outlined: [String: [PatternTypeSummary]] = [:]
            for source in sources {
                guard let self, let summary = try? await self.engine.patternDecoder.summary(of: source) else { continue }
                outlined[source.id] = summary.declaredTypes
            }
            guard let self else { return }
            self.outlines = outlined
            self.expandedSources.formIntersection(sources.map(\.id))
            self.render()
        }
    }
}

extension PatternSource {
    var iconName: String {
        switch origin {
        case .project:
            return kind.iconName
        case .package:
            return "package-x-generic-symbolic"
        }
    }

    var originDescription: String {
        switch origin {
        case .project:
            return workspacePath
        case .package(let package):
            return "From \(package)"
        }
    }
}

extension PatternSource.Kind {
    var title: String {
        switch self {
        case .pattern:
            return "Pattern"
        case .library:
            return "Library"
        }
    }

    var iconName: String {
        switch self {
        case .pattern:
            return "text-x-generic-symbolic"
        case .library:
            return "accessories-dictionary-symbolic"
        }
    }
}

extension PatternTypeKind {
    var title: String {
        switch self {
        case .struct:
            return "Struct"
        case .union:
            return "Union"
        case .enum:
            return "Enum"
        case .bitfield:
            return "Bitfield"
        case .alias:
            return "Alias"
        }
    }

    var iconName: String {
        switch self {
        case .struct, .union:
            return "view-list-symbolic"
        case .enum:
            return "view-list-ordered-symbolic"
        case .bitfield:
            return "input-dialpad-symbolic"
        case .alias:
            return "insert-link-symbolic"
        }
    }
}
