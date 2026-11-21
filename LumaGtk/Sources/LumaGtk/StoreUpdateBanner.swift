import Adw
import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class StoreUpdateBanner {
    let widget: Box
    var prepareForUpdate: () throws -> Void = {}

    private let storefront: Storefront
    private let defID: UUID

    private let headingLabel: Label
    private let installedLabel: Label
    private let sponsorButton: Button
    private let updateButton: Button
    private let progressRow: Box
    private let sponsorshipLabel: Label
    private let signInNote: Label
    private let notesExpander: Expander
    private let notesHost: Box

    private var available: StoreItem?
    private var activity: Activity = .idle
    private var notesVersion: StoreVersion?

    private enum Activity {
        case idle
        case updating
    }

    init(storefront: Storefront, defID: UUID) {
        self.storefront = storefront
        self.defID = defID

        widget = Box(orientation: .vertical, spacing: 4)
        widget.hexpand = true
        widget.visible = false
        widget.add(cssClass: "luma-banner")
        widget.add(cssClass: LumaBannerStyle.news.cssClass)

        let summary = Box(orientation: .horizontal, spacing: 8)

        let leading = Box(orientation: .horizontal, spacing: 8)
        leading.hexpand = true
        leading.valign = .center

        let icon = Image(iconName: "software-update-available-symbolic")
        icon.pixelSize = 16
        icon.valign = .center
        leading.append(child: icon)

        headingLabel = Label(str: "")
        headingLabel.add(cssClass: "heading")
        headingLabel.xalign = 0
        headingLabel.valign = .center
        leading.append(child: headingLabel)

        let divider = Box(orientation: .vertical, spacing: 0)
        divider.add(cssClass: "luma-banner-divider")
        divider.valign = .center
        divider.setSizeRequest(width: 1, height: 16)
        leading.append(child: divider)

        installedLabel = Label(str: "")
        installedLabel.add(cssClass: "caption")
        installedLabel.add(cssClass: "dim-label")
        installedLabel.xalign = 0
        installedLabel.valign = .center
        installedLabel.wrap = true
        installedLabel.hexpand = true
        leading.append(child: installedLabel)

        summary.append(child: leading)

        sponsorButton = Button(label: "")
        sponsorButton.valign = .center
        summary.append(child: sponsorButton)

        updateButton = Button(label: "Update")
        updateButton.valign = .center
        updateButton.add(cssClass: "suggested-action")
        summary.append(child: updateButton)

        progressRow = Box(orientation: .horizontal, spacing: 8)
        progressRow.valign = .center
        progressRow.append(child: makeSpinner())
        let progressLabel = Label(str: "Updating\u{2026}")
        progressLabel.add(cssClass: "dim-label")
        progressRow.append(child: progressLabel)
        summary.append(child: progressRow)

        widget.append(child: summary)

        let details = Box(orientation: .vertical, spacing: 4)
        details.marginStart = 24

        sponsorshipLabel = Self.makeNote()
        details.append(child: sponsorshipLabel)

        signInNote = Self.makeNote()
        signInNote.setMarkup(str: Storefront.signInNoteMarkup("Updating"))
        details.append(child: signInNote)

        notesHost = Box(orientation: .vertical, spacing: 8)
        notesHost.marginTop = 4
        notesExpander = Expander(label: "What\u{2019}s New")
        notesExpander.add(cssClass: "caption")
        notesExpander.set(child: notesHost)
        details.append(child: notesExpander)

        widget.append(child: details)

        sponsorButton.onClicked { [weak self] button in
            MainActor.assumeIsolated { self?.storefront.openSponsorPage(from: button) }
        }
        updateButton.onClicked { [weak self] button in
            MainActor.assumeIsolated {
                guard let self, let item = self.available, let rootPtr = button.root?.ptr else { return }
                self.requestUpdate(to: item, over: Gtk.WindowRef(raw: rootPtr))
            }
        }
        notesExpander.onNotifyExpanded { [weak self] expander, _ in
            MainActor.assumeIsolated {
                guard expander.expanded, let self, self.notesVersion == nil, let item = self.available else { return }
                self.loadNotes(for: item)
            }
        }

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
        guard let installation = storefront.linkedInstallation(ofCustomInstrument: defID),
            case .newer(let item) = installation.latest
        else {
            available = nil
            widget.visible = false
            return
        }
        available = item
        headingLabel.label = "Version \(item.version) is available"
        installedLabel.label = "Version \(installation.installedVersion) is installed."
        showActions(for: item)
        forgetNotes(unlessFor: item)
        widget.visible = true
    }

    private func showActions(for item: StoreItem) {
        let sponsorLabel = storefront.sponsorButtonLabel(for: item)
        let isReachable = sponsorLabel == nil
        let isIdle = activity == .idle
        sponsorButton.label = sponsorLabel ?? ""
        sponsorButton.visible = !isReachable && isIdle
        updateButton.visible = isReachable && isIdle
        progressRow.visible = !isIdle
        let sponsorshipText = storefront.entitlement(for: item) == .entitled ? nil : storefront.sponsorshipText(for: item)
        sponsorshipLabel.label = sponsorshipText ?? ""
        sponsorshipLabel.visible = sponsorshipText != nil
        signInNote.visible = isReachable && storefront.needsSignIn
    }

    private func forgetNotes(unlessFor item: StoreItem) {
        guard let notesVersion, notesVersion != item.version else { return }
        self.notesVersion = nil
        notesExpander.expanded = false
        removeNotes()
    }

    private func requestUpdate(to item: StoreItem, over window: Gtk.WindowRef) {
        do {
            try prepareForUpdate()
        } catch {
            presentError(heading: "Could not update \(item.name)", message: error.localizedDescription, over: window)
            return
        }
        beginUpdate(to: item, over: window, localChanges: .keep)
    }

    private func beginUpdate(to item: StoreItem, over window: Gtk.WindowRef, localChanges: Storefront.LocalChanges) {
        activity = .updating
        render()
        Task { @MainActor in
            await self.update(to: item, over: window, localChanges: localChanges)
            self.activity = .idle
            self.render()
        }
    }

    private func update(to item: StoreItem, over window: Gtk.WindowRef, localChanges: Storefront.LocalChanges) async {
        do {
            try await storefront.install(item, localChanges: localChanges)
        } catch StorefrontError.signInCancelled {
        } catch StorefrontError.rejected(.sponsorshipRequired, _) {
        } catch StorefrontError.localChanges {
            LocalChangesConfirmation.present(
                heading: "Replace Your Edits?",
                body: "\(item.name) has been edited since it was installed. Updating it to \(item.version) replaces those edits.",
                discardLabel: "_Update",
                over: window
            ) { [weak self] in
                self?.beginUpdate(to: item, over: window, localChanges: .discard)
            }
        } catch {
            presentError(heading: "Could not update \(item.name)", message: error.localizedDescription, over: window)
        }
    }

    private func presentError(heading: String, message: String, over window: Gtk.WindowRef) {
        let alert = Adw.AlertDialog(heading: heading, body: message)
        alert.addResponse(id: "ok", label: "OK")
        alert.setDefault(response: "ok")
        alert.setClose(response: "ok")
        alert.present(parent: window)
    }

    private func loadNotes(for item: StoreItem) {
        notesVersion = item.version
        notesHost.append(child: Self.makeLoadingRow())
        let storefront = self.storefront
        Task { @MainActor [weak self] in
            do {
                let versions = try await storefront.versionsSinceInstalled(of: item)
                self?.showNotes(versions, for: item.version)
            } catch {
                self?.showNotesFailure(error, for: item.version)
            }
        }
    }

    private func showNotes(_ versions: [StoreItemVersion], for version: StoreVersion) {
        guard notesVersion == version else { return }
        removeNotes()
        guard !versions.isEmpty else {
            notesHost.append(child: Self.makeNote(text: "No release notes."))
            return
        }
        for entry in versions {
            notesHost.append(child: StoreItemPane.makeVersionEntry(entry))
        }
    }

    private func showNotesFailure(_ error: Swift.Error, for version: StoreVersion) {
        guard notesVersion == version else { return }
        removeNotes()
        notesHost.append(child: Self.makeNote(text: "Could not load what\u{2019}s new: \(error.localizedDescription)"))
    }

    private func removeNotes() {
        while let child = notesHost.firstChild {
            notesHost.remove(child: child)
        }
    }

    private static func makeNote(text: String = "") -> Label {
        let label = Label(str: text)
        label.halign = .start
        label.xalign = 0
        label.wrap = true
        label.add(cssClass: "caption")
        label.add(cssClass: "dim-label")
        return label
    }

    private static func makeLoadingRow() -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.append(child: makeSpinner())
        let label = Label(str: "Loading what\u{2019}s new\u{2026}")
        label.add(cssClass: "dim-label")
        row.append(child: label)
        return row
    }
}
