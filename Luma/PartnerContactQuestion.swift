import LumaCore
import SwiftUI

struct PartnerContactQuestion: View {
    let storefront: Storefront

    var body: some View {
        if storefront.account?.partnerContact == .unanswered {
            PartnerContactPrompt(storefront: storefront)
        }
    }
}

private struct PartnerContactPrompt: View {
    let storefront: Storefront

    @State private var phase: Phase = .asking
    @State private var failure: UIError?

    private enum Phase {
        case asking
        case answering
    }

    var body: some View {
        LumaBanner(style: .info) {
            VStack(alignment: .leading, spacing: 8) {
                question
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("partnerContact.question")
        .partnerContactFailureAlert($failure)
    }

    private var question: some View {
        Label {
            Text(
                """
                NowSecure sponsors Luma. May they contact you about their products and services? They would get your name, email address \
                and GitHub username.
                """
            )
            .font(.callout)
        } icon: {
            Image(systemName: "envelope")
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                privacyPolicyLink
                Spacer(minLength: 16)
                answerButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                privacyPolicyLink
                answerButtons
            }
        }
    }

    private var privacyPolicyLink: some View {
        PrivacyPolicyLink()
            .accessibilityIdentifier("partnerContact.privacyPolicy")
    }

    private var answerButtons: some View {
        HStack(spacing: 8) {
            Button("No Thanks") { answer(.declined) }
                .accessibilityIdentifier("partnerContact.decline")
            Button("Allow") { answer(.allowed) }
                .accessibilityIdentifier("partnerContact.allow")
        }
        .buttonStyle(.bordered)
        .disabled(phase == .answering)
    }

    private func answer(_ choice: PartnerContactChoice) {
        Task { @MainActor in
            phase = .answering
            defer { phase = .asking }
            do {
                try await storefront.answerPartnerContact(choice)
            } catch {
                failure = .unsavedPartnerContactAnswer(error)
            }
        }
    }
}

extension UIError {
    static func unsavedPartnerContactAnswer(_ error: any Error) -> UIError {
        UIError(title: "Could not save your answer", message: error.localizedDescription)
    }
}

extension View {
    func partnerContactFailureAlert(_ failure: Binding<UIError?>) -> some View {
        alert(
            failure.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { failure.wrappedValue != nil },
                set: { if !$0 { failure.wrappedValue = nil } }
            ),
            presenting: failure.wrappedValue
        ) { _ in
            Button("OK") { failure.wrappedValue = nil }
        } message: { presented in
            Text(presented.message)
        }
    }
}
