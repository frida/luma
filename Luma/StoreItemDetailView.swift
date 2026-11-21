import LumaCore
import SwiftUI

struct StoreItemDetailView: View {
    let item: StoreItem
    let storefront: Storefront
    let onUninstall: () -> Void

    @State private var detail: DetailState = .loading

    private enum DetailState {
        case loading
        case loaded(StoreItemDetail)
        case failed(message: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sponsorshipBanner
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    facts
                    Divider()
                    itemDescription
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if storefront.needsSignIn && storefront.installState(of: item).needsDownload {
                    signInNote
                }
                PartnerContactQuestion(storefront: storefront)
                    .background(.bar)
            }
        }
        .task { await loadDetail() }
    }

    @ViewBuilder
    private var sponsorshipBanner: some View {
        switch storefront.entitlementToAdd(item) {
        case .entitled:
            EmptyView()
        case .unknown(let requiredMonthlyCents):
            LumaBanner(style: .info) {
                StoreSponsorshipLabel(explanation: StoreSponsorship.requirement(requiredMonthlyCents: requiredMonthlyCents))
                Spacer()
            }
        case .sponsorshipNeeded(let requiredMonthlyCents, let accountMonthlyCents):
            LumaBanner(style: .info) {
                StoreSponsorshipLabel(
                    explanation: StoreSponsorship.shortfall(
                        requiredMonthlyCents: requiredMonthlyCents,
                        accountMonthlyCents: accountMonthlyCents
                    )
                )
                Spacer()
                StoreSponsorButton(storefront: storefront, accountMonthlyCents: accountMonthlyCents)
                    .accessibilityIdentifier("addInstrument.store.sponsor")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            StoreItemIconView(item: item, storefront: storefront, pointSize: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                Text(item.publisher.name)
                    .foregroundStyle(.secondary)
                Text(item.summary)
                    .padding(.top, 4)
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Version \(item.version.description), published \(item.publishedAt.formatted(date: .abbreviated, time: .omitted))")
            if let categoryName = storefront.categoryName(of: item) {
                Text(categoryName)
            }
            Text(item.access.listingTitle)
            installation
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var installation: some View {
        switch storefront.installState(of: item) {
        case .notInstalled:
            EmptyView()
        case .installed:
            Text("Installed.")
            uninstallButton
        case .updateAvailable(let installed, let latest):
            Text("Version \(installed.description) is installed. Adding it updates it to \(latest.description).")
            uninstallButton
        }
    }

    private var uninstallButton: some View {
        Button("Uninstall", role: .destructive, action: onUninstall)
            .buttonStyle(.bordered)
            .padding(.top, 4)
            .accessibilityIdentifier("addInstrument.store.uninstall")
    }

    @ViewBuilder
    private var itemDescription: some View {
        switch detail {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        case .failed(let message):
            Text("The description could not be loaded.")
                .foregroundStyle(.secondary)
                .help(message)
        case .loaded(let loaded):
            if !loaded.description.isEmpty {
                MarkdownView(loaded.description)
            }
            if !loaded.versions.isEmpty {
                versionHistory(loaded.versions)
            }
        }
    }

    private func versionHistory(_ versions: [StoreItemVersion]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version History")
                .font(.headline)
            ForEach(versions, id: \.version) { version in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(version.version.description)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(version.publishedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !version.notes.isEmpty {
                        Text(version.notes)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var signInNote: some View {
        VStack(spacing: 0) {
            Divider()
            StoreSignInDisclosure(action: .adding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 10)
        }
        .background(.bar)
        .accessibilityIdentifier("addInstrument.store.signInNote")
    }

    private func loadDetail() async {
        do {
            detail = .loaded(try await storefront.detail(of: item))
        } catch {
            detail = .failed(message: error.localizedDescription)
        }
    }
}

struct StoreItemIconView: View {
    let item: StoreItem
    let storefront: Storefront
    var pointSize: CGFloat = 12

    @State private var icon: InstrumentIcon = .symbolic(InstrumentIconCatalog.default.id)

    var body: some View {
        InstrumentIconView(icon: icon, pointSize: pointSize)
            .task(id: item) { icon = await storefront.icon(of: item) }
    }
}

extension Storefront {
    func entitlementToAdd(_ item: StoreItem) -> Entitlement {
        installState(of: item).needsDownload ? entitlement(for: item) : .entitled
    }
}

extension Storefront.InstallState {
    var needsDownload: Bool {
        switch self {
        case .notInstalled, .updateAvailable:
            return true
        case .installed:
            return false
        }
    }

    var badgeTitle: String? {
        switch self {
        case .notInstalled:
            return nil
        case .installed:
            return "Installed"
        case .updateAvailable:
            return "Update"
        }
    }
}

extension StoreAccess {
    var listingTitle: String {
        switch self {
        case .free:
            return "Free"
        case .sponsor(let minimumMonthlyCents):
            return "From \(StorePrice.monthly(cents: minimumMonthlyCents))"
        }
    }
}
