import Adw
import CGtk
import CLuma
import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class WelcomeWindow {
    private weak var application: LumaApplication?
    let window: Adw.ApplicationWindow
    private let welcome: WelcomeModel

    private let clamp: Adw.Clamp
    private let contentBox: Box
    private let quickActionsList: ListBox
    private let labsSection: Box
    private let labsHeaderRow: Box
    private let labsHeaderLabel: Label
    private let labsRefreshButton: Button
    private let signOutButton: Button
    private let labsScroller: ScrolledWindow
    private let labsList: ListBox
    private let labsStateBox: Box
    private let labsSpinner: Adw.Spinner
    private let labsStateLabel: Label
    private let signInBox: Box
    private let signInButton: Button
    private let signInError: Label

    private static let maxVisibleLabs = 4
    private static let labsRowHeight = 56

    private var quickActionHandlers: [UInt: () -> Void] = [:]
    private var labRowsByIdentifier: [UInt: WelcomeModel.LabSummary] = [:]
    private var openSignInDialog: Adw.Dialog?

    init(app: Gtk.Application, application: LumaApplication, welcome: WelcomeModel) {
        self.application = application
        self.welcome = welcome
        self.window = Adw.ApplicationWindow(app: app)
        window.title = "Welcome to Luma"
        window.setDefaultSize(width: 480, height: -1)
        window.add(cssClass: "luma-welcome")

        clamp = Adw.Clamp()
        clamp.set(maximumSize: 520)
        clamp.set(tighteningThreshold: 480)
        clamp.marginStart = 32
        clamp.marginEnd = 32
        clamp.marginTop = 24
        clamp.marginBottom = 44

        contentBox = Box(orientation: .vertical, spacing: 24)
        contentBox.hexpand = true

        quickActionsList = ListBox()

        labsSection = Box(orientation: .vertical, spacing: 12)
        labsHeaderRow = Box(orientation: .horizontal, spacing: 8)
        labsHeaderLabel = Label(str: "Continue from a lab")
        labsRefreshButton = Button(iconName: "view-refresh-symbolic")
        signOutButton = Button(label: "Sign out")
        labsScroller = ScrolledWindow()
        labsList = ListBox()
        labsStateBox = Box(orientation: .horizontal, spacing: 8)
        labsSpinner = Adw.Spinner()
        labsStateLabel = Label(str: "")

        signInBox = Box(orientation: .vertical, spacing: 10)
        signInButton = Button(label: "Sign in with GitHub")
        signInError = Label(str: "")

        buildContent()
        connectSignals()

        clamp.set(child: contentBox)

        let header = Adw.HeaderBar()
        let toolbar = Adw.ToolbarView()
        toolbar.addTopBar(widget: header)
        toolbar.set(content: clamp)
        window.set(content: toolbar)

        let closeHandler: (Gtk.WindowRef) -> Bool = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.application?.welcomeWindowDidClose()
            }
            return false
        }
        window.onCloseRequest(handler: closeHandler)

        observe()
        refresh()
    }

    func present() {
        window.present()
        Task { @MainActor in
            await welcome.bootstrap()
        }
    }

    // MARK: - Content

    private func buildContent() {
        contentBox.append(child: makeHero())
        contentBox.append(child: makeQuickActions())
        contentBox.append(child: makeLabsSection())
    }

    private func makeHero() -> Widget {
        let box = Box(orientation: .vertical, spacing: 16)
        box.halign = .center

        let icon = Image(iconName: "re.frida.Luma")
        icon.pixelSize = 104
        icon.halign = .center
        box.append(child: icon)

        let subtitle = Label(str: "Interactive dynamic instrumentation for Frida.")
        subtitle.add(cssClass: "title-3")
        subtitle.add(cssClass: "dim-label")
        subtitle.halign = .center
        subtitle.wrap = true
        subtitle.justify = .center
        box.append(child: subtitle)

        return box
    }

    private func makeQuickActions() -> Widget {
        quickActionsList.add(cssClass: "boxed-list")
        quickActionsList.selectionMode = .none

        appendQuickAction(
            iconName: "document-new-symbolic",
            title: "New Project",
            subtitle: "Start with an empty workspace."
        ) { [weak self] in
            self?.createBlank()
        }
        appendQuickAction(
            iconName: "document-open-symbolic",
            title: "Open Project\u{2026}",
            subtitle: "Pick a .luma file from disk."
        ) { [weak self] in
            self?.openExisting()
        }

        quickActionsList.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                let key = UInt(bitPattern: row.list_box_row_ptr)
                self?.quickActionHandlers[key]?()
            }
        }

        return quickActionsList
    }

    private func appendQuickAction(
        iconName: String,
        title: String,
        subtitle: String,
        handler: @escaping () -> Void
    ) {
        let row = makeActionRow(iconName: iconName, title: title, subtitle: subtitle)
        quickActionsList.append(child: row)
        let key = UInt(bitPattern: row.list_box_row_ptr)
        quickActionHandlers[key] = handler
    }

    private func makeActionRow(
        iconName: String,
        title: String,
        subtitle: String
    ) -> Adw.ActionRow {
        let row = Adw.ActionRow()
        row.set(title: title)
        row.set(subtitle: subtitle)
        row.activatable = true
        let icon = Image(iconName: iconName)
        icon.pixelSize = 24
        row.addPrefix(widget: icon)
        let chevron = Image(iconName: "go-next-symbolic")
        row.addSuffix(widget: chevron)
        return row
    }

    private func makeLabsSection() -> Widget {
        labsSection.hexpand = true

        labsHeaderLabel.add(cssClass: "title-4")
        labsHeaderLabel.halign = .start
        labsHeaderLabel.hexpand = true
        labsHeaderRow.append(child: labsHeaderLabel)

        labsRefreshButton.add(cssClass: "flat")
        labsRefreshButton.tooltipText = "Refresh"
        labsHeaderRow.append(child: labsRefreshButton)

        signOutButton.add(cssClass: "flat")
        labsHeaderRow.append(child: signOutButton)

        labsSection.append(child: labsHeaderRow)

        labsList.add(cssClass: "boxed-list")
        labsList.selectionMode = .none
        labsList.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                let key = UInt(bitPattern: row.list_box_row_ptr)
                guard let lab = self.labRowsByIdentifier[key] else { return }
                self.openFromLab(lab)
            }
        }

        labsScroller.set(child: labsList)
        labsScroller.propagateNaturalHeight = true
        labsScroller.setPolicy(hscrollbarPolicy: GTK_POLICY_NEVER, vscrollbarPolicy: GTK_POLICY_AUTOMATIC)
        labsScroller.visible = false
        labsSection.append(child: labsScroller)

        labsStateBox.halign = .center
        labsStateBox.marginTop = 8
        labsStateBox.marginBottom = 8
        labsStateLabel.add(cssClass: "dim-label")
        labsStateLabel.wrap = true
        labsStateBox.append(child: labsSpinner)
        labsStateBox.append(child: labsStateLabel)
        labsSection.append(child: labsStateBox)

        signInBox.halign = .fill
        signInBox.add(cssClass: "card")
        signInBox.marginStart = 0
        signInBox.marginEnd = 0
        let signInPadding = Box(orientation: .vertical, spacing: 12)
        signInPadding.marginStart = 18
        signInPadding.marginEnd = 18
        signInPadding.marginTop = 16
        signInPadding.marginBottom = 16
        signInBox.append(child: signInPadding)

        let signInTitle = Label(str: "Continue from a lab")
        signInTitle.add(cssClass: "heading")
        signInTitle.halign = .center
        signInPadding.append(child: signInTitle)

        let signInDescription = Label(
            str: "Sign in with GitHub to find your labs, "
                + "including any started on another machine."
        )
        signInDescription.add(cssClass: "dim-label")
        signInDescription.halign = .center
        signInDescription.justify = .center
        signInDescription.wrap = true
        signInPadding.append(child: signInDescription)

        signInButton.add(cssClass: "suggested-action")
        signInButton.add(cssClass: "pill")
        signInButton.halign = .center
        signInButton.marginTop = 4
        signInPadding.append(child: signInButton)

        signInError.add(cssClass: "error")
        signInError.wrap = true
        signInError.halign = .center
        signInError.justify = .center
        signInError.visible = false
        signInPadding.append(child: signInError)

        signInBox.visible = false
        labsSection.append(child: signInBox)

        return labsSection
    }

    // MARK: - Signals

    private func connectSignals() {
        labsRefreshButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.welcome.refreshLabs() }
            }
        }
        signOutButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.welcome.signOut() }
            }
        }
        signInButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.beginSignIn() }
        }
    }

    private func beginSignIn() {
        welcome.signIn()
        openSignInDialog = GitHubSignInSheet.present(
            from: window,
            gitHubAuth: welcome.gitHubAuth,
            onClosed: { [weak self] in
                self?.openSignInDialog = nil
            }
        )
    }

    // MARK: - Actions

    private func createBlank() {
        guard let application else { return }
        application.openNewUntitledWindow()
        window.close()
    }

    private func openExisting() {
        guard let application else { return }
        application.presentWelcomeOpenDialog(parent: self)
    }

    private func openFromLab(_ lab: WelcomeModel.LabSummary) {
        guard let application else { return }
        let baseDir = LumaAppPaths.shared.untitledDirectory
        let url = Self.untitledURL(in: baseDir, named: lab.title)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
        }
        CollaborationJoinQueue.shared.enqueue(labID: lab.id)
        application.openWindow(forFile: url)
        window.close()
    }

    func handleOpenedFromWelcome(path: String) {
        application?.openWindow(forFile: URL(fileURLWithPath: path))
        window.close()
    }

    // MARK: - Observation

    private func observe() {
        withObservationTracking {
            _ = welcome.gitHubAuth.state
            _ = welcome.gitHubAuth.token
            _ = welcome.labsState
            _ = welcome.labs
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func refresh() {
        let isAuthenticated = welcome.gitHubAuth.token != nil
        signInBox.visible = !isAuthenticated && !isInProgress(welcome.gitHubAuth.state)
        labsHeaderRow.visible = isAuthenticated
        labsRefreshButton.visible = isAuthenticated
        signOutButton.visible = isAuthenticated

        if case .failed(let reason) = welcome.gitHubAuth.state {
            signInError.setText(str: reason)
            signInError.visible = true
        } else {
            signInError.visible = false
        }

        rebuildLabs()
    }

    private func isInProgress(_ state: GitHubAuth.State) -> Bool {
        switch state {
        case .waitingForApproval, .requestingCode, .authenticated:
            return true
        default:
            return false
        }
    }

    private func rebuildLabs() {
        labsList.removeAll()
        labRowsByIdentifier.removeAll()
        switch welcome.labsState {
        case .idle:
            labsScroller.visible = false
            labsStateBox.visible = welcome.gitHubAuth.token != nil
            labsSpinner.visible = false
            labsStateLabel.setText(str:
                welcome.gitHubAuth.token != nil
                    ? "No collaborative labs yet."
                    : ""
            )
        case .loading:
            labsScroller.visible = false
            labsStateBox.visible = true
            labsSpinner.visible = true
            labsStateLabel.setText(str: "Loading labs\u{2026}")
        case .failed(let message):
            labsScroller.visible = false
            labsStateBox.visible = true
            labsSpinner.visible = false
            labsStateLabel.setText(str: message)
        case .loaded:
            if welcome.labs.isEmpty {
                labsScroller.visible = false
                labsStateBox.visible = true
                labsSpinner.visible = false
                labsStateLabel.setText(str: "No collaborative labs yet.")
            } else {
                labsScroller.visible = true
                labsStateBox.visible = false
                for lab in welcome.labs {
                    let row = makeLabRow(lab: lab)
                    let key = UInt(bitPattern: row.list_box_row_ptr)
                    labRowsByIdentifier[key] = lab
                    labsList.append(child: row)
                }
                let visible = min(welcome.labs.count, Self.maxVisibleLabs)
                labsScroller.maxContentHeight = visible * Self.labsRowHeight
                labsScroller.minContentHeight = visible * Self.labsRowHeight
            }
        }
    }

    private func makeLabRow(lab: WelcomeModel.LabSummary) -> Adw.ActionRow {
        let row = Adw.ActionRow()
        row.set(title: lab.title)
        let people = lab.memberCount == 1 ? "1 member" : "\(lab.memberCount) members"
        let subtitle = lab.onlineCount > 0
            ? "\(people) · \(lab.onlineCount) online"
            : people
        row.set(subtitle: subtitle)
        row.activatable = true

        let avatarText = lab.owner?.name ?? lab.title
        let avatar = Adw.Avatar(size: 32, text: avatarText, showInitials: true)
        if let pictureData = lab.pictureData,
           let texture = IconPixbuf.makeTexture(fromEncodedData: pictureData) {
            avatar.set(customImage: texture)
        } else if let owner = lab.owner,
                  let url = owner.avatarURL.flatMap({ URL(string: "\($0.absoluteString)&s=96") }) {
            Task { @MainActor [weak avatar] in
                guard let texture = await AvatarCache.shared.texture(for: url) else { return }
                avatar?.set(customImage: texture)
            }
        }
        row.addPrefix(widget: avatar)

        if lab.role == "owner" {
            let badge = Label(str: "Owner")
            badge.add(cssClass: "caption")
            badge.add(cssClass: "accent")
            row.addSuffix(widget: badge)
        }
        let chevron = Image(iconName: "go-next-symbolic")
        row.addSuffix(widget: chevron)
        return row
    }

    // MARK: - Helpers

    private static func untitledURL(in dir: URL, named rawTitle: String) -> URL {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = rawTitle.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = sanitized.isEmpty ? "Lab" : sanitized
        let fm = FileManager.default
        let primary = dir.appendingPathComponent("\(base).luma")
        if !fm.fileExists(atPath: primary.path) {
            return primary
        }
        for index in 1..<4096 {
            let candidate = dir.appendingPathComponent("\(base) \(index).luma")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return dir.appendingPathComponent("\(base)-\(UUID().uuidString).luma")
    }
}
