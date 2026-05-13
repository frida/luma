import LumaCore
import SwiftUI

struct TracerHookBrowserPopover: View {
    let sessionID: UUID
    let instanceID: UUID
    let hooks: [TracerConfig.Hook]
    @Binding var selection: SidebarItemID?
    let onDismiss: () -> Void

    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            resultsList
        }
        .padding(.vertical, 10)
        .frame(width: 360, height: 420)
        .onAppear { isSearchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter hooks", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit { selectFirstMatch() }
        }
        .padding(.horizontal, 12)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedMatches, id: \.module) { group in
                    Section {
                        ForEach(group.hooks, id: \.id) { hook in
                            hookButton(for: hook)
                        }
                    } header: {
                        moduleHeader(group.module, count: group.hooks.count)
                    }
                }
                if groupedMatches.isEmpty {
                    Text("No matching hooks")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func moduleHeader(_ module: String, count: Int) -> some View {
        HStack {
            Text(module)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.background)
    }

    private func hookButton(for hook: TracerConfig.Hook) -> some View {
        Button {
            choose(hook)
        } label: {
            HStack(spacing: 6) {
                Text(hook.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .opacity(hook.state == .enabled ? 1 : 0.5)
            .help(hook.addressAnchor.displayString)
        }
        .buttonStyle(.plain)
    }

    private var groupedMatches: [HookGroup] {
        let filtered = filteredHooks
        guard !filtered.isEmpty else { return [] }
        var groups: [String: [TracerConfig.Hook]] = [:]
        var order: [String] = []
        for hook in filtered {
            let key = hook.addressAnchor.moduleGroupName
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(hook)
        }
        return order.map { key in
            HookGroup(module: key, hooks: groups[key] ?? [])
        }
    }

    private var filteredHooks: [TracerConfig.Hook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return hooks }
        return hooks.filter { hook in
            hook.displayName.localizedCaseInsensitiveContains(trimmed)
                || hook.addressAnchor.moduleGroupName.localizedCaseInsensitiveContains(trimmed)
                || hook.addressAnchor.displayString.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func selectFirstMatch() {
        guard let first = filteredHooks.first else { return }
        choose(first)
    }

    private func choose(_ hook: TracerConfig.Hook) {
        selection = .instrumentComponent(sessionID, instanceID, hook.id)
        onDismiss()
    }
}

private struct HookGroup {
    let module: String
    let hooks: [TracerConfig.Hook]
}
