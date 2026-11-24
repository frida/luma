import Adw
import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
final class StorePublishDialog {
    private let storefront: Storefront
    private let def: CustomInstrumentDef

    private let dialog: Adw.Dialog
    private let cancelButton: Button
    private let publishButton: Button
    private let publishSpinner: Spinner
    private let failureLabel: Label
    private let scroll: ScrolledWindow
    private let publishesAsLabel: Label
    private let readmeLabel: Label
    private let versionRow: Adw.EntryRow
    private let versionHint: Label
    private let summaryRow: Adw.EntryRow
    private let summaryLengthLabel: Label
    private let categoryRow: Adw.ComboRow
    private let accessRow: Adw.ComboRow
    private let minimumRow: Adw.SpinRow
    private let notesView: TextView

    private var phase: Phase = .connecting
    private var categoryChoices: [StoreCategory.ID] = []

    private enum Phase {
        case connecting
        case editing
        case publishing
    }

    private enum AccessChoice: Int, CaseIterable {
        case free
        case sponsors

        var label: String {
            switch self {
            case .free: return "Free"
            case .sponsors: return "Sponsors"
            }
        }
    }

    private static let summaryLimit = 200
    private static let categoryPrompt = "Choose\u{2026}"

    init(storefront: Storefront, def: CustomInstrumentDef) {
        self.storefront = storefront
        self.def = def

        dialog = Adw.Dialog()
        dialog.set(title: "Publish to Store")
        dialog.set(contentWidth: 520)

        let header = Adw.HeaderBar()
        header.showStartTitleButtons = false
        header.showEndTitleButtons = false
        cancelButton = Button(label: "Cancel")
        header.packStart(child: cancelButton)
        publishButton = Button(label: "Publish")
        publishButton.add(cssClass: "suggested-action")
        publishButton.sensitive = false
        header.packEnd(child: publishButton)
        publishSpinner = makeSpinner()
        publishSpinner.visible = false
        header.packEnd(child: publishSpinner)

        failureLabel = Label(str: "")
        failureLabel.add(cssClass: "error")
        failureLabel.wrap = true
        failureLabel.xalign = 0
        failureLabel.selectable = true
        failureLabel.marginStart = 18
        failureLabel.marginEnd = 18
        failureLabel.marginTop = 12
        failureLabel.visible = false

        publishesAsLabel = Self.makeNote()
        readmeLabel = Self.makeNote()

        versionRow = Adw.EntryRow()
        versionRow.title = "Version"
        versionHint = Self.makeNote()
        versionHint.label = "Use MAJOR.MINOR.PATCH, such as 1.2.0."
        versionHint.add(cssClass: "error")
        versionHint.visible = false

        summaryRow = Adw.EntryRow()
        summaryRow.title = "Summary"
        summaryLengthLabel = Label(str: "")
        summaryLengthLabel.add(cssClass: "caption")
        summaryLengthLabel.add(cssClass: "dim-label")
        summaryLengthLabel.valign = .center
        summaryRow.addSuffix(widget: summaryLengthLabel)

        categoryRow = Adw.ComboRow()
        categoryRow.title = "Category"

        accessRow = Adw.ComboRow()
        accessRow.title = "Access"
        accessRow.set(model: makeStringList(AccessChoice.allCases.map(\.label)))

        minimumRow = Adw.SpinRow(range: 1, max: 10_000, step: 1)
        minimumRow.title = "Minimum per Month"
        minimumRow.subtitle = "US dollars"

        notesView = TextView()
        notesView.wrapMode = .word
        notesView.topMargin = 8
        notesView.bottomMargin = 8
        notesView.leftMargin = 8
        notesView.rightMargin = 8

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.propagateNaturalHeight = true
        scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroll.set(child: Self.makeConnectingPage())

        let content = Box(orientation: .vertical, spacing: 0)
        content.append(child: failureLabel)
        content.append(child: scroll)

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: content)
        dialog.set(child: toolbarView)

        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        publishButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        dialog.onClosed { _ in
            Task { @MainActor in await storefront.close() }
        }
    }

    func present(over parent: Gtk.Window) {
        dialog.own(self)
        dialog.present(parent: parent)
        Task { @MainActor in await connect() }
    }

    private static func makeConnectingPage() -> Box {
        let page = Box(orientation: .vertical, spacing: 12)
        page.halign = .center
        page.valign = .center
        page.marginTop = 48
        page.marginBottom = 48
        page.append(child: makeSpinner())
        let label = Label(str: "Connecting to the Store\u{2026}")
        label.add(cssClass: "dim-label")
        page.append(child: label)
        return page
    }

    private static func makeNote() -> Label {
        let label = Label(str: "")
        label.add(cssClass: "caption")
        label.add(cssClass: "dim-label")
        label.wrap = true
        label.xalign = 0
        label.marginTop = 6
        return label
    }

    private func close() {
        _ = dialog.close()
    }

    private func publish() {
        guard let submission else { return }
        phase = .publishing
        failureLabel.visible = false
        fitHeightToContent()
        refreshValidity()
        Task { @MainActor in
            do {
                try await storefront.publish(
                    customInstrument: def.id,
                    version: submission.version,
                    listing: submission.listing,
                    notes: submission.notes
                )
                close()
                return
            } catch {
                showFailure(error.localizedDescription)
            }
            phase = .editing
            refreshValidity()
        }
    }

    private func connect() async {
        do {
            guard let publisher = try await storefront.requireAccount().publisher else {
                showRefusal(title: "Can\u{2019}t Publish", message: StorefrontError.notPublisher.localizedDescription)
                return
            }
            let draft = try storefront.publishDraft(forCustomInstrument: def.id)
            try await storefront.loadCategories()
            showForm(draft: draft, publisherHandle: publisher.handle)
        } catch StorefrontError.signInCancelled {
            close()
        } catch {
            showRefusal(title: "Can\u{2019}t Publish", message: error.localizedDescription)
        }
    }

    private func showRefusal(title: String, message: String) {
        cancelButton.label = "Close"
        publishButton.visible = false
        scroll.set(child: MainWindow.makeEmptyState(icon: "action-unavailable-symbolic", title: title, subtitle: message))
        fitHeightToContent()
    }

    private func showForm(draft: StorePublishDraft, publisherHandle: String) {
        let notesScroll = ScrolledWindow()
        notesScroll.setSizeRequest(width: -1, height: 120)
        notesScroll.add(cssClass: "card")
        notesScroll.set(child: notesView)

        let notesTitle = Label(str: "What\u{2019}s New")
        notesTitle.halign = .start
        notesTitle.marginTop = 12
        notesTitle.add(cssClass: "heading")

        let releaseGroup = Adw.PreferencesGroup()
        releaseGroup.title = "Release"
        releaseGroup.add(child: versionRow)
        releaseGroup.add(child: versionHint)
        releaseGroup.add(child: notesTitle)
        releaseGroup.add(child: notesScroll)
        releaseGroup.add(child: publishesAsLabel)
        publishesAsLabel.label = "Publishes as \(publisherHandle)/\(draft.slug)."

        let listingGroup = Adw.PreferencesGroup()
        listingGroup.title = "Listing"
        listingGroup.add(child: summaryRow)
        listingGroup.add(child: categoryRow)
        listingGroup.add(child: accessRow)
        listingGroup.add(child: minimumRow)
        listingGroup.add(child: readmeLabel)

        let form = Box(orientation: .vertical, spacing: 18)
        form.marginStart = 18
        form.marginEnd = 18
        form.marginTop = 12
        form.marginBottom = 18
        form.append(child: releaseGroup)
        form.append(child: listingGroup)
        scroll.set(child: form)

        fill(from: draft)

        let refresh: () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.refreshValidity() }
        }
        versionRow.onChanged { _ in refresh() }
        summaryRow.onChanged { _ in refresh() }
        categoryRow.onNotifySelected { _, _ in refresh() }
        accessRow.onNotifySelected { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refreshValidity()
                self?.fitHeightToContent()
            }
        }
        minimumRow.onNotifyValue { _, _ in refresh() }
        notesView.buffer?.onChanged { _ in refresh() }

        phase = .editing
        refreshValidity()
        fitHeightToContent()
    }

    private func fill(from draft: StorePublishDraft) {
        readmeLabel.label =
            draft.description == nil
            ? "The folder has no README.md, so the listing will have no description."
            : "The folder\u{2019}s README.md becomes the description."
        versionRow.text = draft.version?.description ?? ""
        summaryRow.text = draft.listing.summary
        fillCategory(from: draft)
        switch draft.listing.access {
        case .free:
            accessRow.selected = AccessChoice.free.rawValue
        case .sponsor(let minimumMonthlyCents):
            accessRow.selected = AccessChoice.sponsors.rawValue
            minimumRow.value = Double(minimumMonthlyCents) / 100
        }
    }

    private func fillCategory(from draft: StorePublishDraft) {
        let categories = storefront.categories
        categoryChoices = categories.map(\.id)
        categoryRow.set(model: makeStringList([Self.categoryPrompt] + categories.map(\.name)))
        let draftChoice = draft.listing.category.flatMap { categoryChoices.firstIndex(of: $0) }
        categoryRow.selected = draftChoice.map { $0 + 1 } ?? 0
    }

    private func refreshValidity() {
        let versionText = enteredVersionText
        let versionIsInvalid = !versionText.isEmpty && StoreVersion(versionText) == nil
        markInvalid(versionRow, versionIsInvalid)
        versionHint.visible = versionIsInvalid
        let summaryLength = enteredSummary.count
        summaryLengthLabel.label = "\(summaryLength) of \(Self.summaryLimit) characters"
        markInvalid(summaryRow, summaryLength > Self.summaryLimit)
        minimumRow.visible = accessChoice == .sponsors
        publishButton.sensitive = phase == .editing && submission != nil
        publishSpinner.visible = phase == .publishing
    }

    private func markInvalid(_ row: Adw.EntryRow, _ invalid: Bool) {
        if invalid {
            row.add(cssClass: "error")
        } else {
            row.remove(cssClass: "error")
        }
    }

    private var submission: Submission? {
        guard let version = StoreVersion(enteredVersionText) else { return nil }
        let summary = enteredSummary
        guard !summary.isEmpty, summary.count <= Self.summaryLimit, let category = enteredCategory else { return nil }
        let notes = enteredNotes
        guard !notes.isEmpty else { return nil }
        return Submission(
            version: version,
            listing: StoreListing(summary: summary, category: category, access: enteredAccess),
            notes: notes
        )
    }

    private struct Submission {
        let version: StoreVersion
        let listing: StoreListing
        let notes: String
    }

    private var enteredVersionText: String {
        (versionRow.text ?? "").trimmingCharacters(in: .whitespaces)
    }

    private var enteredSummary: String {
        (summaryRow.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var enteredCategory: StoreCategory.ID? {
        let choice = Int(categoryRow.selected)
        guard choice > 0 else { return nil }
        return categoryChoices[choice - 1]
    }

    private var enteredAccess: StoreAccess {
        switch accessChoice {
        case .free:
            return .free
        case .sponsors:
            return .sponsor(minimumMonthlyCents: Int(minimumRow.value.rounded()) * 100)
        }
    }

    private var accessChoice: AccessChoice {
        AccessChoice(rawValue: Int(accessRow.selected))!
    }

    private var enteredNotes: String {
        guard let buffer = notesView.buffer else { return "" }
        let startPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let endPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer {
            startPtr.deallocate()
            endPtr.deallocate()
        }
        let start = TextIter(startPtr)
        let end = TextIter(endPtr)
        buffer.getStart(iter: start)
        buffer.getEnd(iter: end)
        return (buffer.getText(start: start, end: end, includeHiddenChars: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showFailure(_ message: String) {
        failureLabel.label = message
        failureLabel.visible = true
        fitHeightToContent()
    }

    private func fitHeightToContent() {
        dialog.set(contentHeight: -1)
    }
}
