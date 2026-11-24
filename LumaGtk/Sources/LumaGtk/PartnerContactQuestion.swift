import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class PartnerContactQuestion {
    let widget: Box

    private let storefront: Storefront

    private let declineButton: Button
    private let allowButton: Button

    private enum Phase {
        case asking
        case answering
    }

    init(storefront: Storefront) {
        self.storefront = storefront

        widget = Box(orientation: .vertical, spacing: 8)
        widget.hexpand = true
        widget.visible = false
        widget.add(cssClass: "luma-banner")
        widget.add(cssClass: "luma-banner-question")
        widget.add(cssClass: LumaBannerStyle.news.cssClass)

        let questionLabel = Label(
            str: "NowSecure sponsors Luma. May they contact you about their products and services? "
                + "They would get your name, email address and GitHub username."
        )
        questionLabel.halign = .fill
        questionLabel.xalign = 0
        questionLabel.wrap = true
        questionLabel.wrapMode = .wordChar
        widget.append(child: questionLabel)

        let actions = Box(orientation: .horizontal, spacing: 8)

        let policyLink = Label(str: "")
        policyLink.setMarkup(str: PrivacyPolicyLink.markup)
        policyLink.hexpand = true
        policyLink.halign = .start
        policyLink.valign = .center
        actions.append(child: policyLink)

        declineButton = Button(label: "No Thanks")
        declineButton.valign = .center
        actions.append(child: declineButton)

        allowButton = Button(label: "Allow")
        allowButton.valign = .center
        actions.append(child: allowButton)

        widget.append(child: actions)

        declineButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.answer(.declined) }
        }
        allowButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.answer(.allowed) }
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
        widget.visible = storefront.account?.partnerContact == .unanswered
    }

    private func answer(_ choice: PartnerContactChoice) {
        showButtons(for: .answering)
        Task { @MainActor in
            await self.storefront.answerPartnerContact(choice, reportingFailureOver: self.widget)
            self.showButtons(for: .asking)
        }
    }

    private func showButtons(for phase: Phase) {
        let isAsking = phase == .asking
        declineButton.sensitive = isAsking
        allowButton.sensitive = isAsking
    }
}
