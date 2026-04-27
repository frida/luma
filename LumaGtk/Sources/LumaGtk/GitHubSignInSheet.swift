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
    private let captionLabel: Label
    private let codeRow: Box
    private let codeLabel: Label
    private let copyCodeButton: Button
    private let copyCodeImage: Image
    private let openUrlButton: Button
    private let statusRow: Box
    private let statusLabel: Label
    private let errorLabel: Label
    private let cancelButton: Button

    private var copyResetTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    init(gitHubAuth: GitHubAuth) {
        self.gitHubAuth = gitHubAuth

        contentBox = Box(orientation: .vertical, spacing: 16)
        contentBox.marginStart = 24
        contentBox.marginEnd = 24
        contentBox.marginTop = 12
        contentBox.marginBottom = 24
        contentBox.halign = .center

        captionLabel = Label(str: "Go to GitHub and enter the following code:")
        captionLabel.add(cssClass: "dim-label")
        captionLabel.halign = .center
        captionLabel.justify = .center
        captionLabel.wrap = true
        contentBox.append(child: captionLabel)

        codeRow = Box(orientation: .horizontal, spacing: 8)
        codeRow.halign = .center

        let codeFrame = Box(orientation: .horizontal, spacing: 0)
        codeFrame.add(cssClass: "card")
        codeFrame.marginTop = 0

        codeLabel = Label(str: "")
        codeLabel.add(cssClass: "monospace")
        codeLabel.add(cssClass: "title-2")
        codeLabel.halign = .center
        codeLabel.selectable = true
        codeLabel.marginStart = 12
        codeLabel.marginEnd = 12
        codeLabel.marginTop = 6
        codeLabel.marginBottom = 6
        codeFrame.append(child: codeLabel)
        codeRow.append(child: codeFrame)

        copyCodeImage = Image(iconName: "edit-copy-symbolic")
        copyCodeButton = Button()
        copyCodeButton.set(child: copyCodeImage)
        copyCodeButton.tooltipText = "Copy code"
        codeRow.append(child: copyCodeButton)

        contentBox.append(child: codeRow)

        openUrlButton = Button(label: "Open GitHub")
        openUrlButton.add(cssClass: "suggested-action")
        openUrlButton.add(cssClass: "pill")
        openUrlButton.halign = .center
        contentBox.append(child: openUrlButton)

        statusRow = Box(orientation: .horizontal, spacing: 8)
        statusRow.halign = .center
        statusRow.append(child: Adw.Spinner())
        statusLabel = Label(str: "Waiting for authorization\u{2026}")
        statusLabel.add(cssClass: "dim-label")
        statusRow.append(child: statusLabel)
        contentBox.append(child: statusRow)

        errorLabel = Label(str: "")
        errorLabel.add(cssClass: "error")
        errorLabel.halign = .center
        errorLabel.justify = .center
        errorLabel.wrap = true
        errorLabel.visible = false
        contentBox.append(child: errorLabel)

        cancelButton = Button(label: "Cancel")
        cancelButton.halign = .center
        cancelButton.marginTop = 4
        contentBox.append(child: cancelButton)

        copyCodeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.copyCode() }
        }
        openUrlButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.openVerificationUrl() }
        }
        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.closeDialog() }
        }
    }

    private var currentCode: String = ""
    private var currentUrl: URL?

    private func refresh() {
        switch gitHubAuth.state {
        case .signedOut:
            showStatus("Starting sign-in\u{2026}")

        case .waitingForApproval:
            showStatus("Contacting GitHub\u{2026}")

        case .requestingCode(let code, let verifyURL):
            currentCode = code
            currentUrl = verifyURL
            codeLabel.setText(str: code)
            captionLabel.visible = true
            codeRow.visible = true
            openUrlButton.visible = true
            copyCodeButton.sensitive = true
            openUrlButton.sensitive = true
            statusLabel.setText(str: "Waiting for authorization\u{2026}")
            statusRow.visible = true
            errorLabel.visible = false
            cancelButton.label = "Cancel"

        case .authenticated:
            showStatus("Signed in.")
            scheduleClose(after: 0.2)

        case .failed(let reason):
            captionLabel.visible = false
            codeRow.visible = false
            openUrlButton.visible = false
            statusRow.visible = false
            errorLabel.setText(str: "Sign-in failed: \(reason)")
            errorLabel.visible = true
            cancelButton.label = "Close"
        }
    }

    private func showStatus(_ text: String) {
        captionLabel.visible = false
        codeRow.visible = false
        openUrlButton.visible = false
        copyCodeButton.sensitive = false
        openUrlButton.sensitive = false
        statusLabel.setText(str: text)
        statusRow.visible = true
        errorLabel.visible = false
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
        copyCodeImage.setFrom(iconName: "object-select-symbolic")
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if Task.isCancelled { return }
            self?.copyCodeImage.setFrom(iconName: "edit-copy-symbolic")
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
        dialog.set(contentWidth: 380)

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
