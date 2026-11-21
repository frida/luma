import LumaCore
import SwiftUI

struct PartnerContactMenuItems: View {
    let storefront: Storefront
    @Binding var failure: UIError?

    var body: some View {
        if let account = storefront.account {
            Toggle("NowSecure May Contact Me", isOn: contactAllowed(by: account))
                .accessibilityIdentifier("account.partnerContact")
        }
        Button("Privacy Policy") {
            Platform.openURL(BackendConfig.privacyPolicyURL)
        }
        .accessibilityIdentifier("account.privacyPolicy")
    }

    private func contactAllowed(by account: StoreAccount) -> Binding<Bool> {
        Binding(
            get: { account.partnerContact == .allowed },
            set: { answer($0 ? .allowed : .declined) }
        )
    }

    private func answer(_ choice: PartnerContactChoice) {
        Task { @MainActor in
            do {
                try await storefront.answerPartnerContact(choice)
            } catch {
                failure = .unsavedPartnerContactAnswer(error)
            }
        }
    }
}
