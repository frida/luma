import LumaCore
import SwiftUI

struct StoreResultsSection<Row: View>: View {
    let storefront: Storefront
    @ViewBuilder let row: (StoreItem) -> Row

    private enum Display {
        case hidden
        case loading
        case unreachable(message: String)
        case results
        case noMatchesInCategory
    }

    var body: some View {
        switch display {
        case .hidden:
            EmptyView()
        case .loading:
            section {
                progressRow(identifier: "addInstrument.store.loading")
            }
        case .unreachable(let message):
            section {
                retryRow("The store could not be reached.", detail: message, identifier: "addInstrument.store.retry") {
                    Task { await storefront.reload() }
                }
            }
        case .results:
            section {
                ForEach(storefront.results, content: row)
                moreResultsRow
            }
        case .noMatchesInCategory:
            section {
                Text("No matches in this category.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var display: Display {
        switch storefront.state {
        case .failed(let message):
            return .unreachable(message: message)
        case .closed, .loading:
            return storefront.results.isEmpty ? displayWhileFirstPageLoads : .results
        case .loaded:
            return storefront.results.isEmpty ? displayWithoutResults : .results
        }
    }

    private var displayWhileFirstPageLoads: Display {
        isNarrowedBySearchAlone ? .hidden : .loading
    }

    private var displayWithoutResults: Display {
        storefront.category == nil ? .hidden : .noMatchesInCategory
    }

    private var isNarrowedBySearchAlone: Bool {
        !storefront.searchText.isEmpty && storefront.category == nil
    }

    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Section {
            content()
        } header: {
            HStack {
                Text("Store")
                Spacer(minLength: 4)
                if showsCategoryFilter {
                    categoryFilter
                }
            }
        }
    }

    private var showsCategoryFilter: Bool {
        storefront.category != nil || (populatedCategories.count > 1 && catalogItemCount > storefront.firstPageSize)
    }

    private var populatedCategories: [StoreCategory] {
        storefront.categories.filter { $0.itemCount > 0 }
    }

    private var catalogItemCount: Int {
        populatedCategories.map(\.itemCount).reduce(0, +)
    }

    private var categoryFilter: some View {
        Menu {
            Picker("Category", selection: categorySelection) {
                Text(Self.allCategoriesTitle).tag(StoreCategory.ID?.none)
                ForEach(populatedCategories) { category in
                    Text(category.name).tag(StoreCategory.ID?.some(category.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(selectedCategoryName ?? Self.allCategoriesTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .textCase(nil)
        .accessibilityIdentifier("addInstrument.store.category")
    }

    private static var allCategoriesTitle: String {
        "All Categories"
    }

    private var categorySelection: Binding<StoreCategory.ID?> {
        Binding(
            get: { storefront.category },
            set: { category in Task { await storefront.filter(by: category) } }
        )
    }

    private var selectedCategoryName: String? {
        storefront.categories.first { $0.id == storefront.category }?.name
    }

    @ViewBuilder
    private var moreResultsRow: some View {
        switch storefront.moreResults {
        case .allLoaded:
            EmptyView()
        case .available:
            Button(action: loadMore) {
                HStack {
                    Text("Show More")
                    Spacer(minLength: 4)
                    Text("\(storefront.remainingResults.formatted()) remaining")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("addInstrument.store.showMore")
        case .loading:
            progressRow(identifier: "addInstrument.store.loadingMore")
        case .failed(let message):
            retryRow("More could not be loaded.", detail: message, identifier: "addInstrument.store.showMoreRetry", action: loadMore)
        }
    }

    private func loadMore() {
        Task { await storefront.loadMore() }
    }

    private func progressRow(identifier: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Loading\u{2026}")
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier(identifier)
    }

    private func retryRow(_ explanation: String, detail: String, identifier: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(explanation)
                .foregroundStyle(.secondary)
                .help(detail)
            Spacer(minLength: 4)
            Button("Retry", action: action)
                .buttonStyle(.borderless)
                .accessibilityIdentifier(identifier)
        }
    }
}
