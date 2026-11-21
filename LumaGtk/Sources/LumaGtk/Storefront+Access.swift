import Adw
import Foundation
import Gtk
import LumaCore

extension Storefront {
    static func signInNoteMarkup(_ subject: String) -> String {
        PrivacyPolicyLink.markup(
            following: "\(subject) signs you in with GitHub. Luma\u{2019}s server records your GitHub profile, your email address "
                + "and what you download."
        )
    }

    func sponsorshipText(for item: StoreItem) -> String? {
        guard case .sponsor(let minimumMonthlyCents) = item.access else { return nil }
        let requirement = "For sponsors from \(StorePrice.monthly(cents: minimumMonthlyCents))."
        guard case .sponsorshipNeeded(_, let accountMonthlyCents) = entitlement(for: item) else { return requirement }
        return "\(requirement) \(sponsorshipStanding(accountMonthlyCents: accountMonthlyCents))"
    }

    private func sponsorshipStanding(accountMonthlyCents: Int) -> String {
        guard accountMonthlyCents > 0 else { return "You are not a sponsor yet." }
        return "You sponsor \(StorePrice.monthly(cents: accountMonthlyCents))."
    }

    func sponsorButtonLabel(for item: StoreItem) -> String? {
        guard case .sponsorshipNeeded(_, let accountMonthlyCents) = entitlement(for: item) else { return nil }
        return accountMonthlyCents > 0 ? "Change Sponsorship" : "Become a Sponsor"
    }

    func openSponsorPage(from anchor: some Gtk.WidgetProtocol) {
        guard let account else { return }
        let launcher = UriLauncher(uri: account.sponsorURL.absoluteString)
        let parentWindow = anchor.root?.ptr.map { Gtk.WindowRef(raw: $0) }
        launcher.launch(parent: parentWindow, cancellable: nil, callback: nil, userData: nil)
    }

    func answerPartnerContact(_ choice: PartnerContactChoice, reportingFailureOver anchor: some Gtk.WidgetProtocol) async {
        do {
            try await answerPartnerContact(choice)
        } catch {
            let alert = Adw.AlertDialog(heading: "Could not save your answer", body: error.localizedDescription)
            alert.addResponse(id: "ok", label: "OK")
            alert.setDefault(response: "ok")
            alert.setClose(response: "ok")
            alert.present(parent: anchor)
        }
    }
}
