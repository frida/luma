import Adw
import CGtk
import CLuma
import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class AddInstrumentDialog {
    typealias OnAdded = (LumaCore.InstrumentInstance) -> Void

    private static let storeResultsShownAtFirst = 4

    private let dialog: Adw.Dialog
    private let parentWindow: Gtk.Window
    private let descriptors: [LumaCore.InstrumentDescriptor]
    private let libraryFolders: [LumaCore.InstrumentFolder]
    private let disabledDescriptorIDs: Set<String>
    private let systemParameters: SystemParameters?
    private let onAdded: OnAdded?
    private let engine: Engine
    private let storefront: Storefront
    private let sessionID: UUID

    private let listBox: ListBox
    private let searchEntry: SearchEntry
    private let addButton: Button
    private let detailContainer: Box
    private let detailBottomBar: Box
    private let storeHeaderRow: StoreSectionHeaderRow
    private let storeLoadingRow: ListBoxRow
    private let storeUnreachableRow: ListBoxRow
    private let storeNoMatchesRow: ListBoxRow
    private let moreStoreResultsRow: StoreMoreResultsRow
    private let customHeaderRow: ListBoxRow
    private let customDescriptorCount: Int

    private var selectedIndex: Int?
    private var pendingConfigJSON: Data = Data()
    private var tracerEditor: TracerConfigEditor?
    private var customSettingRows: [InstrumentSettingRow] = []
    private var customWidgetsPreview: InstrumentWidgetsRenderer?
    private var codeShareEditor: CodeEditor?
    private var rowKinds: [UnsafeMutableRawPointer: RowKind] = [:]
    private var descriptorRows: [ListBoxRow] = []
    private var libraryFolderRows: [ListBoxRow] = []
    private var searchText = ""
    private var shownStoreSection: StoreSection = .closed
    private var storeResultRows: [StoreItemRow] = []
    private var installedItemRows: [StoreItemRow] = []
    private var storeItemPane: StoreItemPane?
    private var storeActivity: StoreItemPane.Activity = .idle {
        didSet {
            listBox.sensitive = storeActivity == .idle
            dialog.set(canClose: storeActivity == .idle)
            refreshStoreItemDetail()
        }
    }

    private enum RowKind {
        case descriptor(Int)
        case header
        case libraryFolder(Int)
        case newCustom
        case linkFolder
        case storeStatus
        case storeItem(StoreItem.ID)
        case moreStoreResults
    }

    private enum StoreSection: Equatable {
        case closed
        case loading
        case unreachable(message: String)
        case listed
        case noMatchesInCategory
        case empty

        var isLoaded: Bool {
            switch self {
            case .listed, .noMatchesInCategory, .empty:
                return true
            case .closed, .loading, .unreachable:
                return false
            }
        }

        var isShown: Bool {
            switch self {
            case .loading, .unreachable, .listed, .noMatchesInCategory:
                return true
            case .closed, .empty:
                return false
            }
        }
    }

    init(
        parent: Gtk.Window,
        engine: Engine,
        sessionID: UUID,
        descriptors: [LumaCore.InstrumentDescriptor],
        disabledDescriptorIDs: Set<String> = [],
        systemParameters: SystemParameters? = nil,
        onAdded: OnAdded? = nil
    ) {
        self.descriptors = descriptors
        engine.instrumentFolders.reload()
        libraryFolders = engine.instrumentFolders.folders.filter { engine.customInstrumentID(linkedToFolderAt: $0.folderURL) == nil }
        self.disabledDescriptorIDs = disabledDescriptorIDs
        self.systemParameters = systemParameters
        self.onAdded = onAdded
        self.engine = engine
        let storefront = engine.storefront
        self.storefront = storefront
        self.sessionID = sessionID
        self.parentWindow = parent

        dialog = Adw.Dialog()
        dialog.set(title: "Add Instrument")

        listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")

        searchEntry = SearchEntry()
        searchEntry.placeholderText = "Search Instruments"
        searchEntry.marginStart = 12
        searchEntry.marginEnd = 12
        searchEntry.marginTop = 8
        searchEntry.marginBottom = 4

        addButton = Button(label: "Add")
        addButton.add(cssClass: "suggested-action")
        addButton.sensitive = false

        detailContainer = Box(orientation: .vertical, spacing: 0)
        detailContainer.hexpand = true
        detailContainer.vexpand = true

        detailBottomBar = Box(orientation: .vertical, spacing: 0)

        storeHeaderRow = StoreSectionHeaderRow { category in
            Task { await storefront.filter(by: category) }
        }
        storeLoadingRow = Self.makeStoreLoadingRow()
        storeUnreachableRow = Self.makeStoreUnreachableRow(storefront: storefront)
        storeNoMatchesRow = Self.makeStoreNoMatchesRow()
        moreStoreResultsRow = StoreMoreResultsRow {
            Task { await storefront.loadMore() }
        }
        customHeaderRow = Self.makeSectionHeaderRow(title: "Custom Instruments")
        customDescriptorCount = descriptors.filter { $0.kind == .custom }.count

        let header = Adw.HeaderBar()
        let browseButton = Button(label: "Browse CodeShare\u{2026}")
        browseButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.openCodeShareBrowser() }
        }
        header.packStart(child: browseButton)
        header.packEnd(child: addButton)

        let listScroll = ScrolledWindow()
        listScroll.hexpand = false
        listScroll.vexpand = true
        listScroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        listScroll.propagateNaturalWidth = true
        listScroll.set(child: listBox)

        let listPane = Box(orientation: .vertical, spacing: 0)
        listPane.append(child: searchEntry)
        listPane.append(child: listScroll)

        let detailScroll = ScrolledWindow()
        detailScroll.hexpand = true
        detailScroll.vexpand = true
        detailScroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        detailScroll.set(child: detailContainer)

        let detailColumn = Box(orientation: .vertical, spacing: 0)
        detailColumn.append(child: detailScroll)
        detailColumn.append(child: detailBottomBar)

        let paned = Paned(orientation: .horizontal)
        paned.position = 280
        paned.hexpand = true
        paned.vexpand = true
        paned.startChild = WidgetRef(listPane)
        paned.endChild = WidgetRef(detailColumn)
        paned.shrinkStartChild = false
        paned.shrinkEndChild = false

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: paned)
        dialog.set(child: toolbarView)
        dialog.set(defaultWidget: addButton)

        descriptorRows = descriptors.map { descriptor in
            makeDescriptorRow(
                descriptor: descriptor,
                alreadyAdded: disabledDescriptorIDs.contains(descriptor.id),
                incompatibilityReason: incompatibilityReason(for: descriptor.compatibility)
            )
        }
        for (descriptorIndex, descriptor) in descriptors.enumerated() where descriptor.kind != .custom {
            append(descriptorRows[descriptorIndex], as: .descriptor(descriptorIndex))
        }

        append(storeHeaderRow.row, as: .header)
        append(storeLoadingRow, as: .storeStatus)
        append(storeUnreachableRow, as: .storeStatus)
        append(storeNoMatchesRow, as: .storeStatus)
        append(moreStoreResultsRow.row, as: .moreStoreResults)

        append(customHeaderRow, as: .header)
        for (descriptorIndex, descriptor) in descriptors.enumerated() where descriptor.kind == .custom {
            append(descriptorRows[descriptorIndex], as: .descriptor(descriptorIndex))
        }

        for (folderIndex, folder) in libraryFolders.enumerated() {
            let row = makeLibraryFolderRow(folder: folder)
            append(row, as: .libraryFolder(folderIndex))
            libraryFolderRows.append(row)
        }

        append(makeActionRow(iconName: "list-add-symbolic", title: "New Custom Instrument\u{2026}"), as: .newCustom)
        append(makeActionRow(iconName: "folder-symbolic", title: "Link Folder\u{2026}"), as: .linkFolder)

        showPlaceholder(message: "Select an instrument to configure.")

        searchEntry.onSearchChanged { [weak self] entry in
            MainActor.assumeIsolated { self?.search(for: entry.text) }
        }
        searchEntry.onStopSearch { [weak self] entry in
            MainActor.assumeIsolated {
                guard entry.text.isEmpty else {
                    entry.text = ""
                    return
                }
                self?.close()
            }
        }
        searchEntry.onMap { entry in
            _ = entry.grabFocus()
        }

        listBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let row else {
                    self.selectedIndex = nil
                    self.addButton.sensitive = false
                    self.addButton.label = "Add"
                    self.tracerEditor = nil
                    self.showPlaceholder(message: "Select an instrument to configure.")
                    return
                }
                switch self.kind(of: row) {
                case .header, .storeStatus, .moreStoreResults:
                    return
                case .newCustom:
                    self.selectedIndex = nil
                    self.addButton.sensitive = true
                    self.addButton.label = "Add"
                    self.showNewCustomDetail()
                case .libraryFolder(let folderIndex):
                    self.selectedIndex = nil
                    self.addButton.sensitive = true
                    self.addButton.label = "Add"
                    self.showLibraryFolderDetail(folder: self.libraryFolders[folderIndex])
                case .linkFolder:
                    self.selectedIndex = nil
                    self.addButton.sensitive = true
                    self.addButton.label = "Choose Folder\u{2026}"
                    self.showLinkFolderDetail()
                case .descriptor(let descriptorIndex):
                    self.selectedIndex = descriptorIndex
                    let descriptor = self.descriptors[descriptorIndex]
                    let reason = self.incompatibilityReason(for: descriptor.compatibility)
                    self.addButton.sensitive = reason == nil
                    self.addButton.label = "Add"
                    self.refreshDetail()
                case .storeItem(let itemID):
                    self.selectedIndex = nil
                    self.addButton.label = "Add"
                    self.showStoreItemDetail(self.storeItem(withID: itemID))
                }
            }
        }

        listBox.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, case .moreStoreResults = self.kind(of: row) else { return }
                Task { await storefront.loadMore() }
            }
        }

        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }

        dialog.onClosed { _ in
            Task { @MainActor in await storefront.close() }
        }
    }

    func present() {
        dialog.own(self)
        refreshStore()
        dialog.sizeToContent(within: parentWindow)
        dialog.present(parent: parentWindow)
        observeStorefront()
        let systemParameters = self.systemParameters
        Task { await storefront.open(for: systemParameters, showing: Self.storeResultsShownAtFirst) }
    }

    private func refreshStore() {
        let reselectedItemID = selectedStoreItemID
        refreshStoreSection()
        installedItemRows = reconciledRows(installedItemRows, with: storefront.installedItems, from: installedItemRowsStart)
        refreshSearchMatches()
        reselectStoreItem(withID: reselectedItemID)
        refreshStoreItemDetail()
    }

    private var selectedStoreItemID: StoreItem.ID? {
        guard let row = listBox.selectedRow, case .storeItem(let itemID) = kind(of: row) else { return nil }
        return itemID
    }

    private func refreshStoreSection() {
        let section = nextStoreSection
        shownStoreSection = section
        storeHeaderRow.row.visible = section.isShown
        storeHeaderRow.showReloading(section.isLoaded && storefront.state == .loading)
        refreshCategoryFilter()
        storeLoadingRow.visible = section == .loading
        showUnreachability(in: section)
        storeNoMatchesRow.visible = section == .noMatchesInCategory
        storeResultRows = reconciledRows(storeResultRows, with: section == .listed ? storefront.results : [], from: storeResultRowsStart)
        refreshMoreStoreResultsRow(in: section)
    }

    private var nextStoreSection: StoreSection {
        switch storefront.state {
        case .closed:
            return .closed
        case .loading:
            return shownStoreSection.isLoaded ? shownStoreSection : .loading
        case .failed(let message):
            return .unreachable(message: message)
        case .loaded:
            guard storefront.results.isEmpty else { return .listed }
            return storefront.category == nil ? .empty : .noMatchesInCategory
        }
    }

    private func refreshCategoryFilter() {
        let offeredCategories = storefront.categories.filter { $0.itemCount > 0 || $0.id == storefront.category }
        guard categoryFilterEarnsItsPlace(offering: offeredCategories) else {
            storeHeaderRow.hideCategoryFilter()
            return
        }
        storeHeaderRow.showCategoryFilter(offering: offeredCategories, selected: storefront.category)
    }

    private func categoryFilterEarnsItsPlace(offering categories: [StoreCategory]) -> Bool {
        guard storefront.category == nil else { return true }
        let catalogSize = categories.reduce(0) { $0 + $1.itemCount }
        return categories.count > 1 && catalogSize > storefront.firstPageSize
    }

    private func showUnreachability(in section: StoreSection) {
        guard case .unreachable(let message) = section else {
            storeUnreachableRow.visible = false
            return
        }
        storeUnreachableRow.tooltipText = message
        storeUnreachableRow.visible = true
    }

    private var storeResultRowsStart: Int {
        Int(storeNoMatchesRow.index) + 1
    }

    private func refreshMoreStoreResultsRow(in section: StoreSection) {
        let moreResults = storefront.moreResults
        moreStoreResultsRow.row.visible = section == .listed && moreResults != .allLoaded
        moreStoreResultsRow.show(moreResults, remaining: storefront.remainingResults)
    }

    private func reconciledRows(_ rows: [StoreItemRow], with items: [StoreItem], from start: Int) -> [StoreItemRow] {
        let reusableRows = rowsKeepingTheirOrder(rows, in: items)
        let reusableItemIDs = Set(reusableRows.map(\.item.id))
        for row in rows where !reusableItemIDs.contains(row.item.id) {
            remove(row.row)
        }
        let reusableRowsByItemID = Dictionary(uniqueKeysWithValues: reusableRows.map { ($0.item.id, $0) })
        return items.enumerated().map { offset, item in
            if let row = reusableRowsByItemID[item.id] {
                row.show(item, installState: storefront.installState(of: item))
                return row
            }
            let row = makeStoreItemRow(item: item)
            insert(row.row, at: start + offset, as: .storeItem(item.id))
            return row
        }
    }

    private func rowsKeepingTheirOrder(_ rows: [StoreItemRow], in items: [StoreItem]) -> [StoreItemRow] {
        let itemIDs = Set(items.map(\.id))
        let survivingRows = rows.filter { itemIDs.contains($0.item.id) }
        let survivingItemIDs = Set(survivingRows.map(\.item.id))
        let orderInItems = items.map(\.id).filter(survivingItemIDs.contains)
        return survivingRows.map(\.item.id) == orderInItems ? survivingRows : []
    }

    private func makeStoreItemRow(item: StoreItem) -> StoreItemRow {
        StoreItemRow(
            item: item,
            storefront: storefront,
            incompatibilityReason: incompatibilityReason(for: item.compatibility),
            alreadyAdded: isAlreadyAdded(item)
        )
    }

    private func isAlreadyAdded(_ item: StoreItem) -> Bool {
        let folderURL = storefront.installationFolderURL(for: item.id)
        guard let defID = engine.customInstrumentID(linkedToFolderAt: folderURL),
            let def = engine.customInstruments.def(withId: defID)
        else { return false }
        return disabledDescriptorIDs.contains(engine.customInstruments.descriptor(for: def).id)
    }

    private var installedItemRowsStart: Int {
        Int(customHeaderRow.index) + 1 + customDescriptorCount
    }

    private func refreshSearchMatches() {
        let installedItemRowsByLinkedInstrument = self.installedItemRowsByLinkedInstrument
        for (descriptor, row) in zip(descriptors, descriptorRows) {
            let installedItemRow = linkedInstrumentID(of: descriptor).flatMap { installedItemRowsByLinkedInstrument[$0] }
            show(row, named: descriptor.displayName, unlessListedAs: installedItemRow)
        }
        for installedItemRow in installedItemRows {
            installedItemRow.row.visible = matchesSearch(installedItemRow.item.name)
        }
        let installedItemRowsByFolderPath = Dictionary(
            uniqueKeysWithValues: installedItemRows.map { (storefront.installationFolderURL(for: $0.item.id).standardizedFileURL.path, $0) }
        )
        for (folder, row) in zip(libraryFolders, libraryFolderRows) {
            show(row, named: folder.name, unlessListedAs: installedItemRowsByFolderPath[folder.folderURL.standardizedFileURL.path])
        }
    }

    private var installedItemRowsByLinkedInstrument: [UUID: StoreItemRow] {
        Dictionary(
            uniqueKeysWithValues: installedItemRows.compactMap { row in
                engine.customInstrumentID(linkedToFolderAt: storefront.installationFolderURL(for: row.item.id)).map { ($0, row) }
            }
        )
    }

    private func linkedInstrumentID(of descriptor: LumaCore.InstrumentDescriptor) -> UUID? {
        guard descriptor.kind == .custom else { return nil }
        return UUID(uuidString: descriptor.sourceIdentifier)
    }

    private func show(_ row: ListBoxRow, named name: String, unlessListedAs installedItemRow: StoreItemRow?) {
        row.visible = installedItemRow == nil && matchesSearch(name)
        guard let installedItemRow, row.isSelected else { return }
        listBox.select(row: installedItemRow.row)
    }

    private func matchesSearch(_ name: String) -> Bool {
        searchText.isEmpty || name.localizedStandardContains(searchText)
    }

    private func reselectStoreItem(withID itemID: StoreItem.ID?) {
        guard let itemID, listBox.selectedRow == nil,
            let row = (installedItemRows + storeResultRows).first(where: { $0.item.id == itemID })
        else { return }
        listBox.select(row: row.row)
    }

    private func refreshStoreItemDetail() {
        guard let storeItemPane, let item = storeItems.first(where: { $0.id == storeItemPane.item.id }) else { return }
        storeItemPane.show(item, activity: storeActivity)
        addButton.sensitive = canAdd(item)
    }

    private func observeStorefront() {
        withObservationTracking {
            _ = storefront.state
            _ = storefront.results
            _ = storefront.totalResults
            _ = storefront.moreResults
            _ = storefront.installedItems
            _ = storefront.categories
            _ = storefront.installations
            _ = storefront.account
            _ = storefront.needsSignIn
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshStore()
                self.observeStorefront()
            }
        }
    }

    private func search(for text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != searchText else { return }
        searchText = query
        refreshSearchMatches()
        let storefront = self.storefront
        Task { await storefront.search(query) }
    }

    private func storeItem(withID itemID: StoreItem.ID) -> StoreItem {
        storeItems.first { $0.id == itemID }!
    }

    private var storeItems: [StoreItem] {
        storefront.installedItems + storefront.results
    }

    private func canAdd(_ item: StoreItem) -> Bool {
        guard storeActivity == .idle, incompatibilityReason(for: item.compatibility) == nil else { return false }
        let installState = storefront.installState(of: item)
        if case .requiresLuma = installState { return false }
        guard installState.requiresInstall else { return true }
        if case .sponsorshipNeeded = storefront.entitlement(for: item) {
            return false
        }
        return true
    }

    private func incompatibilityReason(for compatibility: InstrumentCompatibility) -> String? {
        systemParameters.flatMap { compatibility.incompatibilityReason(for: $0) }
    }

    private func kind(of row: some ListBoxRowProtocol) -> RowKind {
        rowKinds[row.ptr]!
    }

    private func append(_ row: ListBoxRow, as kind: RowKind) {
        listBox.append(child: row)
        rowKinds[row.ptr] = kind
    }

    private func insert(_ row: ListBoxRow, at position: Int, as kind: RowKind) {
        listBox.insert(child: row, position: position)
        rowKinds[row.ptr] = kind
    }

    private func remove(_ row: ListBoxRow) {
        rowKinds[row.ptr] = nil
        listBox.remove(child: row)
    }

    private static func makeStoreLoadingRow() -> ListBoxRow {
        let row = ListBoxRow()
        row.sensitive = false
        row.selectable = false
        let rowBox = makeStoreStatusBox()
        rowBox.append(child: makeSpinner())
        rowBox.append(child: makeStoreStatusLabel("Loading\u{2026}"))
        row.set(child: rowBox)
        return row
    }

    private static func makeStoreUnreachableRow(storefront: Storefront) -> ListBoxRow {
        let row = ListBoxRow()
        row.selectable = false
        row.activatable = false
        let rowBox = makeStoreStatusBox()
        let label = makeStoreStatusLabel("The store could not be reached.")
        label.hexpand = true
        label.xalign = 0
        label.wrap = true
        rowBox.append(child: label)
        let retryButton = Button(label: "Retry")
        retryButton.add(cssClass: "flat")
        retryButton.valign = .center
        retryButton.onClicked { _ in
            Task { @MainActor in await storefront.reload() }
        }
        rowBox.append(child: retryButton)
        row.set(child: rowBox)
        return row
    }

    private static func makeStoreNoMatchesRow() -> ListBoxRow {
        let row = ListBoxRow()
        row.sensitive = false
        row.selectable = false
        let rowBox = makeStoreStatusBox()
        rowBox.append(child: makeStoreStatusLabel("No matches in this category."))
        row.set(child: rowBox)
        return row
    }

    private static func makeStoreStatusBox() -> Box {
        let rowBox = Box(orientation: .horizontal, spacing: 8)
        rowBox.marginStart = 12
        rowBox.marginEnd = 12
        rowBox.marginTop = 6
        rowBox.marginBottom = 6
        rowBox.valign = .center
        return rowBox
    }

    private static func makeStoreStatusLabel(_ text: String) -> Label {
        let label = Label(str: text)
        label.halign = .start
        label.add(cssClass: "caption")
        label.add(cssClass: "dim-label")
        return label
    }

    private func makeDescriptorRow(
        descriptor: LumaCore.InstrumentDescriptor,
        alreadyAdded: Bool,
        incompatibilityReason: String?
    ) -> ListBoxRow {
        let row = ListBoxRow()
        let rowBox = Box(orientation: .vertical, spacing: 2)
        rowBox.marginStart = 12
        rowBox.marginEnd = 12
        rowBox.marginTop = 6
        rowBox.marginBottom = 6
        rowBox.valign = .center

        let header = Box(orientation: .horizontal, spacing: 8)
        header.append(child: InstrumentIconView.makeImage(for: descriptor.icon, pixelSize: 16))
        let label = Label(str: descriptor.displayName)
        label.halign = .start
        label.hexpand = true
        header.append(child: label)
        if let reason = incompatibilityReason {
            let warning = Gtk.Image(iconName: "dialog-warning-symbolic")
            warning.pixelSize = 12
            warning.tooltipText = reason
            header.append(child: warning)
        }
        rowBox.append(child: header)

        if alreadyAdded {
            let hint = Label(str: "Already added")
            hint.halign = .start
            hint.add(cssClass: "caption")
            hint.add(cssClass: "dim-label")
            hint.marginStart = 25
            rowBox.append(child: hint)
            row.sensitive = false
            row.selectable = false
        }
        row.set(child: rowBox)
        return row
    }

    private static func makeSectionHeaderRow(title: String) -> ListBoxRow {
        let row = ListBoxRow()
        row.sensitive = false
        row.selectable = false
        let label = Label(str: title)
        label.halign = .start
        label.add(cssClass: "caption-heading")
        label.add(cssClass: "dim-label")
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 14
        label.marginBottom = 4
        row.set(child: label)
        return row
    }

    private func makeLibraryFolderRow(folder: LumaCore.InstrumentFolder) -> ListBoxRow {
        let row = ListBoxRow()
        let rowBox = Box(orientation: .horizontal, spacing: 8)
        rowBox.marginStart = 12
        rowBox.marginEnd = 12
        rowBox.marginTop = 6
        rowBox.marginBottom = 6
        rowBox.valign = .center
        rowBox.append(child: InstrumentIconView.makeImage(for: folder.icon, pixelSize: 16))
        let label = Label(str: folder.name)
        label.halign = .start
        label.hexpand = true
        rowBox.append(child: label)
        row.set(child: rowBox)
        return row
    }

    private func makeActionRow(iconName: String, title: String) -> ListBoxRow {
        let row = ListBoxRow()
        let rowBox = Box(orientation: .horizontal, spacing: 8)
        rowBox.marginStart = 12
        rowBox.marginEnd = 12
        rowBox.marginTop = 6
        rowBox.marginBottom = 6
        rowBox.valign = .center
        let icon = Gtk.Image(iconName: iconName)
        icon.pixelSize = 16
        rowBox.append(child: icon)
        let label = Label(str: title)
        label.halign = .start
        label.hexpand = true
        rowBox.append(child: label)
        row.set(child: rowBox)
        return row
    }

    private func appendIncompatibilityBanner(reason: String) {
        let bar = Box(orientation: .horizontal, spacing: 8)
        bar.add(cssClass: "warning")
        bar.marginStart = 0
        bar.marginEnd = 0
        bar.marginTop = 0
        bar.marginBottom = 0
        let inner = Box(orientation: .horizontal, spacing: 8)
        inner.marginStart = 16
        inner.marginEnd = 16
        inner.marginTop = 10
        inner.marginBottom = 10
        let icon = Gtk.Image(iconName: "dialog-warning-symbolic")
        icon.pixelSize = 16
        inner.append(child: icon)
        let label = Label(str: reason)
        label.halign = .start
        label.wrap = true
        label.xalign = 0
        inner.append(child: label)
        bar.append(child: inner)
        detailContainer.append(child: bar)
    }

    private func close() {
        _ = dialog.close()
    }

    private func clearDetail() {
        tracerEditor = nil
        storeItemPane = nil
        while let child = detailContainer.firstChild {
            detailContainer.remove(child: child)
        }
        while let child = detailBottomBar.firstChild {
            detailBottomBar.remove(child: child)
        }
        detailContainer.marginStart = 0
        detailContainer.marginEnd = 0
        detailContainer.marginTop = 0
        detailContainer.marginBottom = 0
        detailContainer.spacing = 0
    }

    private func showPlaceholder(message: String) {
        clearDetail()
        let label = Label(str: message)
        label.halign = .center
        label.valign = .center
        label.hexpand = true
        label.vexpand = true
        label.add(cssClass: "dim-label")
        label.marginStart = 24
        label.marginEnd = 24
        label.marginTop = 24
        label.marginBottom = 24
        detailContainer.append(child: label)
    }

    private func refreshDetail() {
        guard let index = selectedIndex, index < descriptors.count else {
            showPlaceholder(message: "Select an instrument to configure.")
            return
        }
        let descriptor = descriptors[index]
        pendingConfigJSON = descriptor.makeInitialConfigJSON()

        clearDetail()

        if let reason = incompatibilityReason(for: descriptor.compatibility) {
            appendIncompatibilityBanner(reason: reason)
        }

        switch descriptor.kind {
        case .tracer:
            buildTracerEditor(descriptor: descriptor)
        case .codeShare:
            buildCodeShareEditor(descriptor: descriptor)
        case .custom:
            buildCustomInstanceEditor(descriptor: descriptor)
        }
    }

    private func buildCustomInstanceEditor(descriptor: LumaCore.InstrumentDescriptor) {
        let outer = Box(orientation: .vertical, spacing: 8)
        outer.hexpand = true
        outer.marginStart = 24
        outer.marginEnd = 24
        outer.marginTop = 16
        outer.marginBottom = 16
        detailContainer.append(child: outer)

        guard let defID = UUID(uuidString: descriptor.sourceIdentifier),
            let def = engine.customInstruments.def(withId: defID),
            let config = try? CustomInstrumentConfig.decode(from: pendingConfigJSON)
        else {
            outer.append(child: errorLabel("Custom instrument not found"))
            return
        }

        let header = Box(orientation: .horizontal, spacing: 8)
        header.append(child: InstrumentIconView.makeImage(for: def.icon, pixelSize: 16))
        let title = Label(str: def.name)
        title.halign = .start
        title.add(cssClass: "heading")
        header.append(child: title)
        outer.append(child: header)

        customSettingRows.removeAll()
        if !def.settings.isEmpty {
            outer.append(child: InstrumentSettingRow.makeGroup(settings: def.settings, config: config, keeping: &customSettingRows) {
                [weak self] id, state in
                guard let self, var cfg = try? CustomInstrumentConfig.decode(from: self.pendingConfigJSON) else { return }
                cfg.settings[id] = state
                self.pendingConfigJSON = cfg.encode()
            })
        }

        customWidgetsPreview = InstrumentUIHelpers.appendWidgets(into: outer, widgets: def.widgets, engine: engine, instance: nil)
        customWidgetsPreview?.widget.sensitive = false

        pendingConfigJSON = config.encode()
    }

    private func showNewCustomDetail() {
        clearDetail()
        let box = Box(orientation: .vertical, spacing: 12)
        box.halign = .center
        box.valign = .center
        box.hexpand = true
        box.vexpand = true
        box.marginStart = 24
        box.marginEnd = 24
        box.marginTop = 24
        box.marginBottom = 24

        box.append(child: InstrumentIconView.makeImage(for: .symbolic(InstrumentIconCatalog.default.id), pixelSize: 32))

        let title = Label(str: "Create a Custom Instrument")
        title.add(cssClass: "title-3")
        box.append(child: title)

        let hint = Label(str: "Custom instruments are TypeScript snippets you write inline. They are saved with the project, can be added to multiple sessions, and synchronized when collaboration is enabled. After creating one you can rename it, choose an icon, and define toggleable settings from the sidebar.")
        hint.add(cssClass: "dim-label")
        hint.wrap = true
        hint.justify = .center
        box.append(child: hint)
        detailContainer.append(child: box)
    }

    private func showLibraryFolderDetail(folder: LumaCore.InstrumentFolder) {
        showFolderDetail(
            title: folder.name,
            hint: "This instrument lives in \(folder.folderURL.path). Adding it brings it into the project as a custom instrument that stays linked to the folder: when the files change, Luma offers to reload it."
        )
    }

    private func showLinkFolderDetail() {
        showFolderDetail(
            title: "Link Folder",
            hint: "Pick a folder holding a package.json and a TypeScript entry file. The instrument is brought into the project as a custom instrument that stays linked to the folder: when the files change, Luma offers to reload it."
        )
    }

    private func showFolderDetail(title: String, hint: String) {
        clearDetail()
        let box = Box(orientation: .vertical, spacing: 12)
        box.halign = .center
        box.valign = .center
        box.hexpand = true
        box.vexpand = true
        box.marginStart = 24
        box.marginEnd = 24
        box.marginTop = 24
        box.marginBottom = 24

        let titleLabel = Label(str: title)
        titleLabel.add(cssClass: "title-3")
        box.append(child: titleLabel)

        let hintLabel = Label(str: hint)
        hintLabel.add(cssClass: "dim-label")
        hintLabel.wrap = true
        hintLabel.justify = .center
        box.append(child: hintLabel)
        detailContainer.append(child: box)
    }

    private func showStoreItemDetail(_ item: StoreItem) {
        clearDetail()
        if let reason = incompatibilityReason(for: item.compatibility) {
            appendIncompatibilityBanner(reason: reason)
        }
        let pane = StoreItemPane(storefront: storefront, item: item, activity: storeActivity) { [weak self] item in
            self?.uninstallStoreItem(item)
        }
        storeItemPane = pane
        detailContainer.append(child: pane.widget)
        detailBottomBar.append(child: pane.bottomBar)
        addButton.sensitive = canAdd(item)
    }

    private func buildTracerEditor(descriptor: LumaCore.InstrumentDescriptor) {
        guard let config = try? TracerConfig.decode(from: pendingConfigJSON) else {
            showPlaceholder(message: "Failed to decode tracer config.")
            return
        }
        let editor = TracerConfigEditor(
            engine: engine,
            sessionID: sessionID,
            config: config,
            isConfigOnly: true,
            apply: { [weak self] data in
                MainActor.assumeIsolated { self?.pendingConfigJSON = data }
            }
        )
        tracerEditor = editor
        detailContainer.append(child: editor.widget)
    }

    private func buildCodeShareEditor(descriptor: LumaCore.InstrumentDescriptor) {
        guard let config = try? JSONDecoder().decode(CodeShareConfig.self, from: pendingConfigJSON) else {
            showPlaceholder(message: "Failed to decode codeshare config")
            return
        }

        if config.source.isEmpty {
            showCodeShareEmptyState()
            return
        }

        buildCodeShareForm(descriptor: descriptor, initialConfig: config)
    }

    private func showCodeShareEmptyState() {
        clearDetail()
        addButton.sensitive = false

        let box = Box(orientation: .vertical, spacing: 12)
        box.halign = .center
        box.valign = .center
        box.hexpand = true
        box.vexpand = true
        box.marginStart = 24
        box.marginEnd = 24
        box.marginTop = 24
        box.marginBottom = 24

        let icon = Image(iconName: "cloud-symbolic")
        icon.pixelSize = 48
        icon.add(cssClass: "dim-label")
        box.append(child: icon)

        let title = Label(str: "No snippet loaded")
        title.add(cssClass: "title-3")
        box.append(child: title)

        let hint = Label(str: "Browse CodeShare to pick a snippet to instrument.")
        hint.add(cssClass: "dim-label")
        hint.wrap = true
        hint.justify = .center
        box.append(child: hint)

        let browse = Button(label: "Browse CodeShare\u{2026}")
        browse.add(cssClass: "suggested-action")
        browse.halign = .center
        browse.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.openCodeShareBrowser() }
        }
        box.append(child: browse)

        detailContainer.append(child: box)
    }

    private func buildCodeShareForm(
        descriptor: LumaCore.InstrumentDescriptor,
        initialConfig: CodeShareConfig
    ) {
        var config = initialConfig
        detailContainer.marginStart = 24
        detailContainer.marginEnd = 24
        detailContainer.marginTop = 16
        detailContainer.marginBottom = 16
        detailContainer.spacing = 8

        let title = Label(str: config.name.isEmpty ? descriptor.displayName : config.name)
        title.halign = .start
        title.add(cssClass: "title-3")
        detailContainer.append(child: title)

        if let project = config.project {
            let sub = Label(str: "@\(project.owner)/\(project.slug)")
            sub.halign = .start
            sub.add(cssClass: "caption")
            sub.add(cssClass: "dim-label")
            detailContainer.append(child: sub)
        } else {
            let sub = Label(str: "Local snippet (not published)")
            sub.halign = .start
            sub.add(cssClass: "caption")
            sub.add(cssClass: "dim-label")
            detailContainer.append(child: sub)
        }

        let nameRow = Box(orientation: .horizontal, spacing: 8)
        nameRow.append(child: Label(str: "Name"))
        let nameEntry = Entry()
        nameEntry.text = config.name
        nameEntry.hexpand = true
        nameRow.append(child: nameEntry)
        detailContainer.append(child: nameRow)

        let descRow = Box(orientation: .horizontal, spacing: 8)
        descRow.append(child: Label(str: "Description"))
        let descEntry = Entry()
        descEntry.text = config.description
        descEntry.hexpand = true
        descRow.append(child: descEntry)
        detailContainer.append(child: descRow)

        let codeHeader = Label(str: "Source")
        codeHeader.halign = .start
        codeHeader.add(cssClass: "heading")
        codeHeader.marginTop = 8
        detailContainer.append(child: codeHeader)

        let editorContainer = Box(orientation: .vertical, spacing: 0)
        editorContainer.hexpand = true
        editorContainer.vexpand = true
        editorContainer.setSizeRequest(width: -1, height: 320)
        detailContainer.append(child: editorContainer)

        let editor = CodeEditor(engine: engine, profile: EditorProfile.fridaCodeShare(), initialText: config.source)
        codeShareEditor = editor
        editor.installInto(editorContainer)

        var currentSource = config.source
        let sync: () -> Void = { [weak self] in
            guard let self else { return }
            config.name = nameEntry.text ?? ""
            config.description = descEntry.text ?? ""
            config.source = currentSource
            config.lastReviewedHash = config.currentSourceHash
            if let data = try? JSONEncoder().encode(config) {
                self.pendingConfigJSON = data
            }
        }
        nameEntry.onChanged { _ in MainActor.assumeIsolated { sync() } }
        descEntry.onChanged { _ in MainActor.assumeIsolated { sync() } }
        editor.onTextChanged = { text in
            MainActor.assumeIsolated {
                currentSource = text
                sync()
            }
        }

        sync()
    }

    private func errorLabel(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "error")
        label.halign = .start
        return label
    }

    private func commit() {
        if let row = listBox.selectedRow {
            switch kind(of: row) {
            case .newCustom:
                commitNewCustom()
                return
            case .storeItem(let itemID):
                commitStoreItem(storeItem(withID: itemID))
                return
            case .libraryFolder(let folderIndex):
                linkFolderAndAdd(libraryFolders[folderIndex].folderURL)
                return
            case .linkFolder:
                presentLinkFolderPicker()
                return
            case .header, .storeStatus, .moreStoreResults, .descriptor:
                break
            }
        }
        guard let index = selectedIndex, index < descriptors.count else { return }
        let descriptor = descriptors[index]
        let engine = self.engine
        let sessionID = self.sessionID
        let onAdded = self.onAdded
        let configJSON = pendingConfigJSON
        Task { @MainActor in
            let instance = await engine.addInstrument(
                kind: descriptor.kind,
                sourceIdentifier: descriptor.sourceIdentifier,
                configJSON: configJSON,
                sessionID: sessionID
            )
            if let instance {
                onAdded?(instance)
            }
        }
        close()
    }

    private func commitNewCustom() {
        let engine = self.engine
        let sessionID = self.sessionID
        let onAdded = self.onAdded
        Task { @MainActor in
            let def = engine.createCustomInstrument()
            let configJSON = CustomInstrumentConfig(
                defID: def.id,
                settings: CustomInstrumentLibrary.initialSettingStates(for: def)
            ).encode()
            let instance = await engine.addInstrument(
                kind: .custom,
                sourceIdentifier: def.id.uuidString,
                configJSON: configJSON,
                sessionID: sessionID
            )
            if let instance {
                onAdded?(instance)
            }
        }
        close()
    }

    private func commitStoreItem(_ item: StoreItem, localChanges: Storefront.LocalChanges = .keep) {
        let folderURL = storefront.installationFolderURL(for: item.id)
        guard storefront.installState(of: item).requiresInstall else {
            linkFolderAndAdd(folderURL)
            return
        }
        storeActivity = .installing
        Task { @MainActor in
            let isInstalled = await install(item, localChanges: localChanges)
            storeActivity = .idle
            if isInstalled {
                linkFolderAndAdd(folderURL)
            }
        }
    }

    private func install(_ item: StoreItem, localChanges: Storefront.LocalChanges) async -> Bool {
        do {
            try await storefront.install(item, localChanges: localChanges)
            return true
        } catch StorefrontError.signInCancelled {
        } catch StorefrontError.rejected(.sponsorshipRequired, _) {
        } catch StorefrontError.localChanges {
            LocalChangesConfirmation.present(
                heading: "Replace Your Edits?",
                body: "\(item.name) has been edited since it was installed. Installing \(item.version) replaces those edits.",
                discardLabel: "_Replace",
                over: parentWindow
            ) { [weak self] in
                self?.commitStoreItem(item, localChanges: .discard)
            }
        } catch {
            presentError(heading: "Could not add \(item.name)", message: error.localizedDescription)
        }
        return false
    }

    private func uninstallStoreItem(_ item: StoreItem, localChanges: Storefront.LocalChanges = .keep) {
        do {
            try storefront.uninstall(itemID: item.id, localChanges: localChanges)
        } catch StorefrontError.localChanges {
            LocalChangesConfirmation.present(
                heading: "Delete Your Edits?",
                body: "\(item.name) has been edited since it was installed. Uninstalling it deletes those edits.",
                discardLabel: "_Uninstall",
                over: parentWindow
            ) { [weak self] in
                self?.uninstallStoreItem(item, localChanges: .discard)
            }
        } catch {
            presentError(heading: "Could not uninstall \(item.name)", message: error.localizedDescription)
        }
    }

    private func presentLinkFolderPicker() {
        guard let parentPtr = parentWindow.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        "Choose instrument folder".withCString { title in
            luma_folder_dialog_select(parentPtr, title, addInstrumentImportFolderThunk, context)
        }
    }

    fileprivate func handleImportFolder(_ path: String?) {
        guard let path else { return }
        linkFolderAndAdd(URL(fileURLWithPath: path))
    }

    private func linkFolderAndAdd(_ folderURL: URL) {
        let engine = self.engine
        let sessionID = self.sessionID
        let onAdded = self.onAdded
        do {
            let def = try engine.linkInstrumentFolder(at: folderURL)
            Task { @MainActor in
                let configJSON = CustomInstrumentConfig(
                    defID: def.id,
                    settings: CustomInstrumentLibrary.initialSettingStates(for: def)
                ).encode()
                let instance = await engine.addInstrument(
                    kind: .custom,
                    sourceIdentifier: def.id.uuidString,
                    configJSON: configJSON,
                    sessionID: sessionID
                )
                if let instance {
                    onAdded?(instance)
                }
            }
            close()
        } catch {
            presentError(heading: "Could not link folder", message: error.localizedDescription)
        }
    }

    private func presentError(heading: String, message: String) {
        let alert = Adw.AlertDialog(heading: heading, body: message)
        alert.addResponse(id: "ok", label: "OK")
        alert.setDefault(response: "ok")
        alert.setClose(response: "ok")
        alert.present(parent: parentWindow)
    }

    private func openCodeShareBrowser() {
        let parent = parentWindow
        close()
        CodeShareBrowser.present(from: parent, engine: engine, sessionID: sessionID)
    }
}

private let addInstrumentImportFolderThunk: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let userData else { return }
    let dialog = Unmanaged<AddInstrumentDialog>.fromOpaque(userData).takeRetainedValue()
    let path = pathPtr.map { String(cString: $0) }
    Task { @MainActor in
        dialog.handleImportFolder(path)
    }
}

