import LumaCore
import SwiftUI

struct StorePublishSheet: View {
    let defID: UUID
    let engine: Engine

    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage = .connecting
    @State private var fields = ReleaseFields()
    @State private var submission: Submission = .editing
    @State private var formFittingHeight: CGFloat?


    private enum Stage {
        case connecting
        case notPublisher
        case ready(publisherHandle: String, slug: String, hasReadme: Bool)
        case failed(message: String)
    }

    private enum Submission: Equatable {
        case editing
        case publishing
        case rejected(message: String)
    }

    private var storefront: Storefront {
        engine.storefront
    }

    var body: some View {
        layout
            .gitHubSignInSheet(auth: engine.gitHubAuth, precedence: .foremost)
            .task { await prepare() }
            .onDisappear { Task { await storefront.close() } }
    }

    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        desktopLayout
        #else
        NavigationStack { compactLayout }
        #endif
    }

    private var desktopLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Publish to Store")
                .font(.title2.bold())
                .padding(.horizontal)
                .padding(.top)

            content

            if case .rejected(let message) = submission {
                rejectionNotice(message)
                    .padding(.horizontal)
                    .padding(.top)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if submission == .publishing {
                    ProgressView()
                        .controlSize(.small)
                }
                publishButton
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    #if !os(macOS)
    private var compactLayout: some View {
        content
            .safeAreaInset(edge: .top) {
                if case .rejected(let message) = submission {
                    rejectionNotice(message)
                        .padding()
                        .background(.bar)
                }
            }
            .navigationTitle("Publish to Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    publishButton
                }
            }
    }
    #endif

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .connecting:
            ProgressView("Connecting to the Store\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notPublisher:
            ContentUnavailableView(
                "Can\u{2019}t Publish",
                systemImage: "storefront",
                description: Text(StorefrontError.notPublisher.localizedDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(
                "Can\u{2019}t Publish",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let publisherHandle, let slug, let hasReadme):
            form(publisherHandle: publisherHandle, slug: slug, hasReadme: hasReadme)
                .formStyle(.grouped)
                #if os(macOS)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                } action: { _, fittingHeight in
                    formFittingHeight = fittingHeight
                }
                .frame(idealHeight: formFittingHeight)
                #endif
        }
    }

    private func form(publisherHandle: String, slug: String, hasReadme: Bool) -> some View {
        Form {
            Section {
                releaseFields
            } header: {
                Text("Release")
            } footer: {
                Text("Publishes as \(publisherHandle)/\(slug).")
            }
            listingSection(hasReadme: hasReadme)
        }
    }

    @ViewBuilder
    private var releaseFields: some View {
        TextField("Version", text: $fields.version, prompt: Text("1.0.0"))
            .autocorrectionDisabled()
            .accessibilityIdentifier("storePublish.version")
        if !fields.version.isEmpty, version == nil {
            Text("Use MAJOR.MINOR.PATCH, such as 1.2.0.")
                .font(.caption)
                .foregroundStyle(.red)
        }
        TextField("What\u{2019}s New", text: $fields.notes, prompt: Text("Shown in the version history"), axis: .vertical)
            .lineLimit(2...6)
            .accessibilityIdentifier("storePublish.notes")
    }

    private func listingSection(hasReadme: Bool) -> some View {
        Section("Listing") {
            TextField("Summary", text: $fields.summary, axis: .vertical)
                .lineLimit(1...4)
                .accessibilityIdentifier("storePublish.summary")
            Text("\(summary.count) of \(StoreListing.summaryLimit) characters")
                .font(.caption)
                .foregroundStyle(summary.count > StoreListing.summaryLimit ? .red : .secondary)

            Picker("Category", selection: $fields.category) {
                Text("Choose\u{2026}").tag(StoreCategory.ID?.none)
                ForEach(storefront.categories) { category in
                    Text(category.name).tag(StoreCategory.ID?.some(category.id))
                }
            }
            .accessibilityIdentifier("storePublish.category")

            Picker("Access", selection: $fields.access) {
                Text("Free").tag(AccessChoice.free)
                Text("Sponsors").tag(AccessChoice.sponsors)
            }
            .accessibilityIdentifier("storePublish.access")

            if fields.access == .sponsors {
                minimumSponsorshipField
            }

            Label(
                hasReadme
                    ? "The folder\u{2019}s README.md becomes the description."
                    : "The folder has no README.md, so the listing will have no description.",
                systemImage: "doc.text"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var minimumSponsorshipField: some View {
        LabeledContent("Minimum per Month") {
            HStack(spacing: 2) {
                Text("$")
                TextField("Minimum per Month", value: $fields.minimumMonthlyDollars, format: .number, prompt: Text("5"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                    #if canImport(UIKit)
                    .keyboardType(.numberPad)
                    #endif
                    .accessibilityIdentifier("storePublish.minimum")
            }
        }
    }

    private func rejectionNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier("storePublish.rejection")
    }

    private var publishButton: some View {
        Button("Publish") { publish() }
            .disabled(!isReadyToPublish)
            .accessibilityIdentifier("storePublish.publish")
    }

    private var isReadyToPublish: Bool {
        guard case .ready = stage else { return false }
        return submission != .publishing && version != nil && listing != nil && !notes.isEmpty
    }

    private var version: StoreVersion? {
        StoreVersion(fields.version.trimmingCharacters(in: .whitespaces))
    }

    private var listing: StoreListing? {
        guard !summary.isEmpty, summary.count <= StoreListing.summaryLimit, let category = fields.category, let access else { return nil }
        return StoreListing(summary: summary, category: category, access: access)
    }

    private var summary: String {
        fields.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var access: StoreAccess? {
        switch fields.access {
        case .free:
            return .free
        case .sponsors:
            guard let dollars = fields.minimumMonthlyDollars, dollars > 0 else { return nil }
            return .sponsor(minimumMonthlyCents: dollars * 100)
        }
    }

    private var notes: String {
        fields.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func publish() {
        guard let version, let listing else { return }
        submission = .publishing
        Task { @MainActor in
            do {
                try await storefront.publish(
                    customInstrument: defID,
                    version: version,
                    listing: listing,
                    notes: notes
                )
                dismiss()
            } catch {
                submission = .rejected(message: error.localizedDescription)
            }
        }
    }

    private func prepare() async {
        do {
            guard let publisher = try await storefront.requireAccount().publisher else {
                stage = .notPublisher
                return
            }
            let draft = try storefront.publishDraft(forCustomInstrument: defID)
            try await storefront.loadCategories()
            fields = ReleaseFields(draft: draft, categories: storefront.categories)
            stage = .ready(publisherHandle: publisher.handle, slug: draft.slug, hasReadme: draft.description != nil)
        } catch StorefrontError.signInCancelled {
            dismiss()
        } catch {
            stage = .failed(message: error.localizedDescription)
        }
    }
}

private struct ReleaseFields {
    var version = ""
    var summary = ""
    var category: StoreCategory.ID?
    var access: AccessChoice = .free
    var minimumMonthlyDollars: Int? = 5
    var notes = ""

    init() {}

    init(draft: StorePublishDraft, categories: [StoreCategory]) {
        version = draft.version?.description ?? ""
        summary = draft.listing.summary
        category = categories.first { $0.id == draft.listing.category }?.id
        switch draft.listing.access {
        case .free:
            access = .free
        case .sponsor(let minimumMonthlyCents):
            access = .sponsors
            minimumMonthlyDollars = minimumMonthlyCents / 100
        }
    }
}

private enum AccessChoice: Hashable {
    case free
    case sponsors
}
