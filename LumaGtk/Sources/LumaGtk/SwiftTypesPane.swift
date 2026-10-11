import Adw
import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
final class SwiftTypesPane {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let module: LumaCore.ProcessModule
    private let onChoose: @MainActor (SwiftTypeSummary) -> Void

    private var types: [SwiftTypeSummary] = []
    private var visibleTypes: [SwiftTypeSummary] = []
    private var query = ""
    private var rowModel: StringList?
    private var rowViews: [UnsafeMutableRawPointer: RowView] = [:]
    private var loadTask: Task<Void, Never>?

    private final class RowView {
        let box: Box
        let badge: Label
        let nameLabel: Label
        let kindLabel: Label

        init(box: Box, badge: Label, nameLabel: Label, kindLabel: Label) {
            self.box = box
            self.badge = badge
            self.nameLabel = nameLabel
            self.kindLabel = kindLabel
        }
    }

    init(
        engine: Engine,
        sessionID: UUID,
        module: LumaCore.ProcessModule,
        onChoose: @escaping @MainActor (SwiftTypeSummary) -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.module = module
        self.onChoose = onChoose

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        show(makeMessage("Loading\u{2026}"))
        load()
    }

    deinit {
        loadTask?.cancel()
    }

    private func load() {
        guard let node = engine?.node(forSessionID: sessionID) else {
            show(makeMessage("Process detached"))
            return
        }
        let moduleName = module.name
        loadTask = Task { @MainActor [weak self] in
            do {
                let outline = try await node.outlineModule(name: moduleName)
                guard let self, !Task.isCancelled else { return }
                self.render(outline.swiftTypes)
            } catch {
                self?.show(self?.makeMessage(error.localizedDescription))
            }
        }
    }

    private func render(_ outline: SwiftTypesOutline) {
        switch outline {
        case .available(let types):
            self.types = types
            show(makeTypeList())
        case .needsBridge:
            show(makeInstallPrompt(error: nil))
        case .absent:
            show(MainWindow.makeEmptyState(
                icon: "applications-engineering-symbolic",
                title: "No Swift Types",
                subtitle: "\(module.name) carries no Swift metadata."
            ))
        }
    }

    private func show(_ content: Widget?) {
        while let child = widget.firstChild {
            widget.remove(child: child)
        }
        if let content {
            widget.append(child: content)
        }
    }

    private func makeTypeList() -> Widget {
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
                self.onChoose(self.visibleTypes[Int(position)])
            }
        }
        configure(factory)
        self.rowModel = rowModel
        refreshRows()

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: listView)

        let filterEntry = SearchEntry()
        filterEntry.placeholderText = "Filter"
        filterEntry.hexpand = true
        filterEntry.onSearchChanged { [weak self] entry in
            MainActor.assumeIsolated {
                self?.query = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.refreshRows()
            }
        }

        let filterBar = Box(orientation: .horizontal, spacing: 6)
        filterBar.marginStart = 10
        filterBar.marginEnd = 10
        filterBar.marginTop = 5
        filterBar.marginBottom = 5
        filterBar.append(child: filterEntry)

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: scroll)
        column.append(child: Separator(orientation: .horizontal))
        column.append(child: filterBar)
        return column
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
                self.bind(rowView, to: self.visibleTypes[item.position])
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
        visibleTypes = types.filter(matches)
        guard let rowModel else { return }
        "".withCString { blank in
            let additions = [UnsafePointer<CChar>?](repeating: blank, count: visibleTypes.count) + [nil]
            additions.withUnsafeBufferPointer {
                rowModel.splice(position: 0, nRemovals: rowModel.nItems, additions: $0.baseAddress)
            }
        }
    }

    private func matches(_ type: SwiftTypeSummary) -> Bool {
        query.isEmpty || type.name.localizedCaseInsensitiveContains(query)
    }

    private func bind(_ rowView: RowView, to type: SwiftTypeSummary) {
        rowView.badge.setText(str: type.kind.badgeLetter)
        rowView.nameLabel.setText(str: type.displayName(inModule: module.name))
        rowView.kindLabel.setText(str: type.kind.title)
        rowView.box.tooltipText = type.name
    }

    private func makeRowView() -> RowView {
        let box = Box(orientation: .horizontal, spacing: 8)
        box.marginStart = 6
        box.marginEnd = 6
        box.marginTop = 2
        box.marginBottom = 2

        let badge = ModuleSidebar.makeKindBadge(.class)
        badge.hexpand = false
        badge.setSizeRequest(width: 16, height: -1)

        let nameLabel = Label(str: "")
        nameLabel.halign = .start
        nameLabel.hexpand = true
        nameLabel.ellipsize = .end

        let kindLabel = Label(str: "")
        kindLabel.add(cssClass: "dim-label")
        kindLabel.add(cssClass: "caption")

        box.append(child: badge)
        box.append(child: nameLabel)
        box.append(child: kindLabel)
        return RowView(box: box, badge: badge, nameLabel: nameLabel, kindLabel: kindLabel)
    }

    private func makeInstallPrompt(error: String?) -> Widget {
        let name = SwiftTypesOutline.bridgePackageName
        let description = "Browsing Swift types needs the \(name) package."
        return MainWindow.makeEmptyState(
            icon: "applications-engineering-symbolic",
            title: "Swift Types",
            subtitle: error.map { "\(description)\n\n\($0)" } ?? description,
            actionLabel: "Install \(name)",
            onAction: { [weak self] in self?.install() }
        )
    }

    private func install() {
        guard let engine else { return }
        show(makeMessage("Installing \(SwiftTypesOutline.bridgePackageName)\u{2026}"))
        loadTask = Task { @MainActor [weak self] in
            do {
                try await engine.installSwiftBridge()
                self?.load()
            } catch {
                self?.show(self?.makeInstallPrompt(error: error.localizedDescription))
            }
        }
    }

    private func makeMessage(_ text: String) -> Widget {
        let label = Label(str: text)
        label.add(cssClass: "dim-label")
        label.halign = .center
        label.valign = .center
        label.hexpand = true
        label.vexpand = true
        label.wrap = true
        return label
    }
}
