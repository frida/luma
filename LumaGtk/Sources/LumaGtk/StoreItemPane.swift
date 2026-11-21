import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class StoreItemPane {
    enum Activity {
        case idle
        case installing
    }

    let widget: Box
    private(set) var item: StoreItem

    var bottomBar: Box {
        partnerContactQuestion.widget
    }

    private let storefront: Storefront
    private let onUninstall: (StoreItem) -> Void

    private let nameLabel: Label
    private let publisherLabel: Label
    private let releaseLabel: Label
    private let summaryLabel: Label
    private let installationLabel: Label
    private let sponsorshipLabel: Label
    private let signInNote: Label
    private let partnerContactQuestion: PartnerContactQuestion
    private let actions: Box
    private let sponsorButton: Button
    private let uninstallButton: Button
    private let progressRow: Box
    private let detailHost: Box
    private let detailLoadingRow: Box

    init(storefront: Storefront, item: StoreItem, activity: Activity, onUninstall: @escaping (StoreItem) -> Void) {
        self.storefront = storefront
        self.item = item
        self.onUninstall = onUninstall

        widget = Box(orientation: .vertical, spacing: 8)
        widget.hexpand = true
        widget.marginStart = 24
        widget.marginEnd = 24
        widget.marginTop = 16
        widget.marginBottom = 16

        let header = Box(orientation: .horizontal, spacing: 12)
        let icon = InstrumentIconView.makeImage(for: item, from: storefront, pixelSize: 32)
        icon.valign = .start
        header.append(child: icon)
        let titles = Box(orientation: .vertical, spacing: 2)
        titles.hexpand = true
        nameLabel = Label(str: "")
        nameLabel.halign = .start
        nameLabel.wrap = true
        nameLabel.xalign = 0
        nameLabel.add(cssClass: "title-3")
        titles.append(child: nameLabel)
        publisherLabel = Label(str: "")
        publisherLabel.halign = .start
        publisherLabel.add(cssClass: "dim-label")
        titles.append(child: publisherLabel)
        header.append(child: titles)
        widget.append(child: header)

        releaseLabel = Self.makeParagraph(cssClasses: ["caption", "dim-label"])
        widget.append(child: releaseLabel)

        summaryLabel = Self.makeParagraph(cssClasses: [])
        summaryLabel.selectable = true
        widget.append(child: summaryLabel)

        installationLabel = Self.makeParagraph(cssClasses: ["dim-label"])
        widget.append(child: installationLabel)

        sponsorshipLabel = Self.makeParagraph(cssClasses: ["dim-label"])
        widget.append(child: sponsorshipLabel)

        signInNote = Self.makeParagraph(cssClasses: ["caption", "dim-label"])
        signInNote.setMarkup(str: Storefront.signInNoteMarkup("Adding it"))
        widget.append(child: signInNote)

        partnerContactQuestion = PartnerContactQuestion(storefront: storefront)

        actions = Box(orientation: .horizontal, spacing: 8)
        sponsorButton = Button(label: "")
        actions.append(child: sponsorButton)
        uninstallButton = Button(label: "Uninstall")
        actions.append(child: uninstallButton)
        progressRow = Box(orientation: .horizontal, spacing: 8)
        progressRow.append(child: makeSpinner())
        let progressLabel = Label(str: "Installing\u{2026}")
        progressLabel.add(cssClass: "dim-label")
        progressRow.append(child: progressLabel)
        actions.append(child: progressRow)
        widget.append(child: actions)

        let separator = Separator(orientation: .horizontal)
        separator.marginTop = 4
        widget.append(child: separator)

        detailHost = Box(orientation: .vertical, spacing: 12)
        detailLoadingRow = Box(orientation: .horizontal, spacing: 8)
        detailLoadingRow.append(child: makeSpinner())
        let loadingLabel = Label(str: "Loading the description\u{2026}")
        loadingLabel.add(cssClass: "dim-label")
        detailLoadingRow.append(child: loadingLabel)
        detailHost.append(child: detailLoadingRow)
        widget.append(child: detailHost)

        sponsorButton.onClicked { [weak self] button in
            MainActor.assumeIsolated { self?.storefront.openSponsorPage(from: button) }
        }
        uninstallButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onUninstall(self.item)
            }
        }

        show(item, activity: activity)
        loadDetail()
    }

    func show(_ item: StoreItem, activity: Activity) {
        self.item = item
        nameLabel.label = item.name
        publisherLabel.label = item.publisher.name
        releaseLabel.label = releaseText
        summaryLabel.label = item.summary
        let installState = storefront.installState(of: item)
        show(installationText(installState), in: installationLabel)
        show(storefront.sponsorshipText(for: item), in: sponsorshipLabel)
        signInNote.visible = storefront.needsSignIn && installState.requiresInstall
        showActions(installState: installState, activity: activity)
    }

    private var releaseText: String {
        let release = "Version \(item.version) \u{00B7} Published \(item.publishedAt.formatted(date: .abbreviated, time: .omitted))"
        guard let categoryName = storefront.categoryName(of: item) else { return release }
        return "\(categoryName) \u{00B7} \(release)"
    }

    private func show(_ text: String?, in label: Label) {
        label.label = text ?? ""
        label.visible = text != nil
    }

    private func installationText(_ installState: Storefront.InstallState) -> String? {
        switch installState {
        case .notInstalled, .installed:
            return nil
        case .updateAvailable(let installed, let latest):
            return "Version \(installed) is installed. Adding it updates it to \(latest)."
        }
    }

    private func showActions(installState: Storefront.InstallState, activity: Activity) {
        let sponsorLabel = storefront.sponsorButtonLabel(for: item)
        sponsorButton.label = sponsorLabel ?? ""
        sponsorButton.visible = sponsorLabel != nil
        uninstallButton.visible = installState != .notInstalled
        uninstallButton.sensitive = activity == .idle
        progressRow.visible = activity == .installing
        actions.visible = sponsorButton.visible || uninstallButton.visible || progressRow.visible
    }

    private func loadDetail() {
        let storefront = self.storefront
        let item = self.item
        Task { @MainActor [weak self] in
            do {
                let detail = try await storefront.detail(of: item)
                self?.showDetail(detail)
            } catch {
                self?.showDetailFailure(error)
            }
        }
    }

    private func showDetail(_ detail: StoreItemDetail) {
        detailHost.remove(child: detailLoadingRow)
        if !detail.description.isEmpty {
            detailHost.append(child: MarkdownWidget.make(markdown: detail.description, as: .document))
        }
        guard !detail.versions.isEmpty else { return }
        let versionsHeading = Label(str: "Version History")
        versionsHeading.halign = .start
        versionsHeading.add(cssClass: "heading")
        versionsHeading.marginTop = 8
        detailHost.append(child: versionsHeading)
        for version in detail.versions {
            detailHost.append(child: Self.makeVersionEntry(version))
        }
    }

    static func makeVersionEntry(_ version: StoreItemVersion) -> Box {
        let entry = Box(orientation: .vertical, spacing: 4)

        let title = Box(orientation: .horizontal, spacing: 8)
        let versionLabel = Label(str: version.version.description)
        versionLabel.add(cssClass: "heading")
        title.append(child: versionLabel)
        let dateLabel = Label(str: version.publishedAt.formatted(date: .abbreviated, time: .omitted))
        dateLabel.add(cssClass: "caption")
        dateLabel.add(cssClass: "dim-label")
        title.append(child: dateLabel)
        entry.append(child: title)

        if !version.notes.isEmpty {
            entry.append(child: MarkdownWidget.make(markdown: version.notes, as: .conversation, dimmed: true))
        }
        return entry
    }

    private func showDetailFailure(_ error: Swift.Error) {
        detailHost.remove(child: detailLoadingRow)
        let label = Self.makeParagraph(cssClasses: ["dim-label"])
        label.label = "Could not load the description: \(error.localizedDescription)"
        detailHost.append(child: label)
    }

    private static func makeParagraph(cssClasses: [String]) -> Label {
        let label = Label(str: "")
        label.halign = .start
        label.xalign = 0
        label.wrap = true
        for cssClass in cssClasses {
            label.add(cssClass: cssClass)
        }
        return label
    }
}

extension Storefront.InstallState {
    var requiresInstall: Bool {
        switch self {
        case .notInstalled, .updateAvailable:
            return true
        case .installed:
            return false
        }
    }
}
