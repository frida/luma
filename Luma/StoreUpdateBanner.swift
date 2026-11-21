import LumaCore
import SwiftUI

struct StoreUpdateBanner: View {
    let defID: UUID
    let engine: Engine
    var prepareForUpdate: @MainActor () throws -> Void = {}

    var body: some View {
        if let installation = engine.storefront.linkedInstallation(ofCustomInstrument: defID), let item = installation.newerItem {
            StoreUpdateOffer(
                item: item,
                installedVersion: installation.installedVersion,
                engine: engine,
                prepareForUpdate: prepareForUpdate
            )
        }
    }
}

private struct StoreUpdateOffer: View {
    let item: StoreItem
    let installedVersion: StoreVersion
    let engine: Engine
    let prepareForUpdate: @MainActor () throws -> Void

    @State private var releaseNotes: ReleaseNotesState = .loading
    @State private var isUpdating = false
    @State private var isConfirmingReplace = false
    @State private var failure: UIError?

    private enum ReleaseNotesState {
        case loading
        case loaded([StoreItemVersion])
        case failed(message: String)
    }

    private var storefront: Storefront {
        engine.storefront
    }

    var body: some View {
        let entitlement = storefront.entitlement(for: item)
        LumaBanner(style: .info) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label {
                        Text(availability)
                            .font(.callout)
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                    Spacer()
                    action(for: entitlement)
                }
                sponsorshipNote(for: entitlement)
                releaseNotesSection
                if storefront.needsSignIn {
                    StoreSignInDisclosure(action: .updating)
                        .accessibilityIdentifier("customInstrument.update.signInNote")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Replace Your Edits?", isPresented: $isConfirmingReplace, titleVisibility: .visible) {
            Button("Update", role: .destructive) {
                update(localChanges: .discard)
            }
            .accessibilityIdentifier("customInstrument.update.replace")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(item.name) has been edited since it was installed. Updating it to \(item.version.description) replaces those edits.")
        }
        .alert(failure?.title ?? "", isPresented: failureBinding, presenting: failure) { _ in
            Button("OK") { failure = nil }
        } message: { failure in
            Text(failure.message)
        }
        .task(id: item) { await loadReleaseNotes() }
    }

    private var availability: String {
        "Version \(item.version.description) is available. Version \(installedVersion.description) is installed."
    }

    @ViewBuilder
    private func action(for entitlement: Storefront.Entitlement) -> some View {
        switch entitlement {
        case .entitled, .unknown:
            if isUpdating {
                updateProgress
            } else {
                Button("Update") {
                    update(localChanges: .keep)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("customInstrument.update")
            }
        case .sponsorshipNeeded(_, let accountMonthlyCents):
            StoreSponsorButton(storefront: storefront, accountMonthlyCents: accountMonthlyCents)
                .accessibilityIdentifier("customInstrument.update.sponsor")
        }
    }

    private var updateProgress: some View {
        ProgressView()
            .controlSize(.small)
            .gitHubSignInSheet(auth: engine.gitHubAuth, precedence: .foremost)
    }

    private func update(localChanges: Storefront.LocalChanges) {
        Task { @MainActor in
            isUpdating = true
            defer { isUpdating = false }
            do {
                try prepareForUpdate()
                try await storefront.install(item, localChanges: localChanges)
            } catch StorefrontError.signInCancelled, StorefrontError.rejected(.sponsorshipRequired, _) {
            } catch StorefrontError.localChanges {
                isConfirmingReplace = true
            } catch {
                failure = UIError(title: "Could not update \(item.name)", message: error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private func sponsorshipNote(for entitlement: Storefront.Entitlement) -> some View {
        switch entitlement {
        case .entitled:
            EmptyView()
        case .unknown(let requiredMonthlyCents):
            StoreSponsorshipLabel(explanation: StoreSponsorship.requirement(requiredMonthlyCents: requiredMonthlyCents))
        case .sponsorshipNeeded(let requiredMonthlyCents, let accountMonthlyCents):
            StoreSponsorshipLabel(
                explanation: StoreSponsorship.shortfall(
                    requiredMonthlyCents: requiredMonthlyCents,
                    accountMonthlyCents: accountMonthlyCents
                )
            )
        }
    }

    @ViewBuilder
    private var releaseNotesSection: some View {
        switch releaseNotes {
        case .loading:
            EmptyView()
        case .loaded(let versions):
            let versionsWithNotes = versions.filter { !$0.notes.isEmpty }
            if !versionsWithNotes.isEmpty {
                StoreReleaseNotes(versions: versionsWithNotes)
            }
        case .failed(let message):
            Text("What\u{2019}s new could not be loaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(message)
        }
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )
    }

    private func loadReleaseNotes() async {
        do {
            releaseNotes = .loaded(try await storefront.versionsSinceInstalled(of: item))
        } catch {
            releaseNotes = .failed(message: error.localizedDescription)
        }
    }
}

private struct StoreReleaseNotes: View {
    let versions: [StoreItemVersion]

    @State private var extent: Extent = .excerpt

    private enum Extent {
        case excerpt
        case full
    }

    private static let excerptLineCount = 2
    private static let fullHeightLimit: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch extent {
            case .excerpt:
                releaseNote(version: newest.version, notes: newestExcerpt)
            case .full:
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(versions, id: \.version) { version in
                            releaseNote(version: version.version, notes: version.notes)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Self.fullHeightLimit)
                .fixedSize(horizontal: false, vertical: true)
            }
            if isLong {
                Button(extent == .excerpt ? "Show More" : "Show Less", action: toggleExtent)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityIdentifier("customInstrument.update.releaseNotes")
            }
        }
    }

    private var newest: StoreItemVersion {
        versions[0]
    }

    private var newestExcerpt: String {
        newestLines.prefix(Self.excerptLineCount).joined(separator: "\n")
    }

    private func releaseNote(version: StoreVersion, notes: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(version.description)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(notes)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isLong: Bool {
        versions.count > 1 || newestLines.count > Self.excerptLineCount
    }

    private func toggleExtent() {
        extent = extent == .excerpt ? .full : .excerpt
    }

    private var newestLines: [Substring] {
        newest.notes.split(separator: "\n", omittingEmptySubsequences: false)
    }
}

extension Storefront.LinkedInstallation {
    var newerItem: StoreItem? {
        guard case .newer(let item) = latest else { return nil }
        return item
    }
}
