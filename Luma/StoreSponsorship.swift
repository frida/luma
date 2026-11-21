import LumaCore
import SwiftUI

enum StoreSponsorship {
    static func shortfall(requiredMonthlyCents: Int, accountMonthlyCents: Int) -> String {
        "\(requirement(requiredMonthlyCents: requiredMonthlyCents)) \(standing(accountMonthlyCents: accountMonthlyCents))"
    }

    static func requirement(requiredMonthlyCents: Int) -> String {
        "For sponsors from \(StorePrice.monthly(cents: requiredMonthlyCents))."
    }

    private static func standing(accountMonthlyCents: Int) -> String {
        accountMonthlyCents == 0 ? "You are not a sponsor yet." : "You sponsor \(StorePrice.monthly(cents: accountMonthlyCents))."
    }
}

struct StoreSponsorshipLabel: View {
    let explanation: String

    var body: some View {
        Label {
            Text(explanation)
                .font(.callout)
        } icon: {
            Image(systemName: "heart")
        }
    }
}

struct StoreSponsorButton: View {
    let storefront: Storefront
    let accountMonthlyCents: Int

    var body: some View {
        #if os(macOS)
        if let account = storefront.account {
            Button(accountMonthlyCents == 0 ? "Become a Sponsor" : "Change Sponsorship") {
                Platform.openURL(account.sponsorURL)
            }
            .buttonStyle(.bordered)
        }
        #endif
    }
}
