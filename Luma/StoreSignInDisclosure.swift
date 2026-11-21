import SwiftUI

struct StoreSignInDisclosure: View {
    let action: Action

    enum Action {
        case adding
        case updating
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .foregroundStyle(.secondary)
                PrivacyPolicyLink()
            }
        } icon: {
            Image(systemName: "person.badge.key")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var text: String {
        """
        \(action.signingInClause) signs you in with GitHub. Luma\u{2019}s server records your GitHub profile, \
        your email address and what you download.
        """
    }
}

private extension StoreSignInDisclosure.Action {
    var signingInClause: String {
        switch self {
        case .adding:
            return "Adding it"
        case .updating:
            return "Updating"
        }
    }
}
