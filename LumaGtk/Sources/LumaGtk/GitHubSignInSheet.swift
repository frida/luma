import Adw
import Foundation
import Gdk
import Gtk
import LumaCore
import Observation

@MainActor
final class GitHubSignInSheet {
    private weak var dialog: Adw.Dialog?
    private let gitHubAuth: GitHubAuth

    private let contentBox: Box
    private let headerLabel: Label
    private let captionLabel: Label
    private let codeLabel: Label
    private let urlLabel: Label
    private let copyCodeButton: Button
    private let openUrlButton: Button
    private let statusRow: Box
    private let statusLabel: Label
    private let errorLabel: Label
    private let dismissButton: Button

    private var closeTask: Task<Void, Never>?

    init(gitHubAuth: GitHubAuth) {
        self.gitHubAuth = gitHubAuth

        contentBox = Box(orientation: .vertical, spacing: 12)
        contentBox.marginStart = 24
        contentBox.marginEnd = 24
        contentBox.marginTop = 20
        contentBox.marginBottom = 20
        contentBox.hexpand = true
        contentBox.vexpand = true

        headerLabel = Label(str: "Sign in to GitHub")
        headerLabel.add(cssClass: "title-3")
        headerLabel.halign = .start
        contentBox.append(child: headerLabel)

        captionLabel = Label(str: "To collaborate, authorize Luma using the device flow below.")
        captionLabel.add(cssClass: "dim-label")
        captionLabel.halign = .start
        captionLabel.wrap = true
        contentBox.append(child: captionLabel)

        let detailsBox = Box(orientation: .vertical, spacing: 8)
        detailsBox.marginTop = 8

        codeLabel = Label(str: "")
        codeLabel.add(cssClass: "monospace")
        codeLabel.add(cssClass: "title-1")
        codeLabel.halign = .center
        codeLabel.selectable = true
        detailsBox.append(child: codeLabel)

        urlLabel = Label(str: "")
        urlLabel.add(cssClass: "link")
        urlLabel.halign = .center
        urlLabel.selectable = true
        urlLabel.wrap = true
        detailsBox.append(child: urlLabel)

        let buttonRow = Box(orientation: .horizontal, spacing: 8)
        buttonRow.halign = .center
        buttonRow.marginTop = 4

        copyCodeButton = Button(label: "Copy code")
        buttonRow.append(child: copyCodeButton)

        openUrlButton = Button(label: "Open verification URL")
        openUrlButton.add(cssClass: "suggested-action")
        buttonRow.append(child: openUrlButton)

        detailsBox.append(child: buttonRow)
        contentBox.append(child: detailsBox)

        statusRow = Box(orientation: .horizontal, spacing: 8)
        statusRow.halign = .center
        statusRow.marginTop = 8
        statusRow.append(child: Adw.Spinner())
        statusLabel = Label(str: "Waiting for authorization\u{2026}")
        statusLabel.add(cssClass: "dim-label")
        statusRow.append(child: statusLabel)
        contentBox.append(child: statusRow)

        errorLabel = Label(str: "")
        errorLabel.add(cssClass: "error")
        errorLabel.halign = .start
        errorLabel.wrap = true
        errorLabel.visible = false
        contentBox.append(child: errorLabel)

        dismissButton = Button(label: "Dismiss")
        dismissButton.halign = .end
        dismissButton.visible = false
        contentBox.append(child: dismissButton)

        copyCodeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.copyCode() }
        }
        openUrlButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.openVerificationUrl() }
        }
        dismissButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.closeDialog() }
        }
    }

    private var currentCode: String = ""
    private var currentUrl: URL?

    private func refresh() {
        switch gitHubAuth.state {
        case .signedOut:
            codeLabel.setText(str: "\u{2014}")
            urlLabel.setText(str: "")
            copyCodeButton.sensitive = false
            openUrlButton.sensitive = false
            statusLabel.setText(str: "Starting sign-in\u{2026}")
            statusRow.visible = true
            errorLabel.visible = false
            dismissButton.visible = false

        case .waitingForApproval:
            codeLabel.setText(str: "\u{2014}")
            urlLabel.setText(str: "")
            copyCodeButton.sensitive = false
            openUrlButton.sensitive = false
            statusLabel.setText(str: "Contacting GitHub\u{2026}")
            statusRow.visible = true
            errorLabel.visible = false
            dismissButton.visible = false

        case .requestingCode(let code, let verifyURL):
            currentCode = code
            currentUrl = verifyURL
            codeLabel.setText(str: code)
            urlLabel.setText(str: verifyURL.absoluteString)
            copyCodeButton.sensitive = true
            openUrlButton.sensitive = true
            statusLabel.setText(str: "Waiting for authorization\u{2026}")
            statusRow.visible = true
            errorLabel.visible = false
            dismissButton.visible = false

        case .authenticated:
            statusLabel.setText(str: "Signed in.")
            scheduleClose(after: 0.2)

        case .failed(let reason):
            statusRow.visible = false
            errorLabel.setText(str: "Sign-in failed: \(reason)")
            errorLabel.visible = true
            dismissButton.visible = true
            copyCodeButton.sensitive = false
            openUrlButton.sensitive = false
        }
    }

    private func observe() {
        withObservationTracking {
            _ = gitHubAuth.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func copyCode() {
        guard !currentCode.isEmpty else { return }
        if let display = Display.getDefault() {
            display.clipboard.set(text: currentCode)
        }
    }

    private func openVerificationUrl() {
        guard let url = currentUrl else { return }
        let launcher = UriLauncher(uri: url.absoluteString)
        let parentWindow: Gtk.WindowRef?
        if let rootPtr = dialog?.root?.ptr {
            parentWindow = Gtk.WindowRef(raw: rootPtr)
        } else {
            parentWindow = nil
        }
        launcher.launch(parent: parentWindow, cancellable: nil, callback: nil, userData: nil)
    }

    private func scheduleClose(after seconds: Double) {
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.closeDialog()
        }
    }

    private func closeDialog() {
        _ = dialog?.close()
    }
}

@MainActor
extension GitHubSignInSheet {
    @discardableResult
    static func present(
        from anchor: Widget,
        gitHubAuth: GitHubAuth,
        onClosed: (() -> Void)? = nil
    ) -> Adw.Dialog {
        let sheet = GitHubSignInSheet(gitHubAuth: gitHubAuth)

        let dialog = Adw.Dialog()
        dialog.set(title: "Sign in to GitHub")
        dialog.set(contentWidth: 480)
        dialog.set(contentHeight: 320)

        let header = Adw.HeaderBar()

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: sheet.contentBox)
        dialog.set(child: toolbarView)

        sheet.dialog = dialog
        Self.retain(sheet: sheet, dialog: dialog, gitHubAuth: gitHubAuth, onClosed: onClosed)

        sheet.refresh()
        sheet.observe()

        dialog.present(parent: anchor)

        return dialog
    }

    private static var retained: [ObjectIdentifier: GitHubSignInSheet] = [:]

    private static func retain(
        sheet: GitHubSignInSheet,
        dialog: Adw.Dialog,
        gitHubAuth: GitHubAuth,
        onClosed: (() -> Void)?
    ) {
        let key = ObjectIdentifier(dialog)
        retained[key] = sheet
        dialog.onClosed { _ in
            MainActor.assumeIsolated {
                switch gitHubAuth.state {
                case .authenticated:
                    break
                case .failed:
                    gitHubAuth.resetState()
                default:
                    gitHubAuth.cancelSignIn()
                }
                gitHubAuth.dismissSignIn()
                _ = retained.removeValue(forKey: key)
                onClosed?()
            }
        }
    }
}
