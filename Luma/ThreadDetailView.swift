import LumaCore
import SwiftUI

struct ThreadDetailView: View {
    let sessionID: UUID
    let thread: LumaCore.ProcessThread
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var snapshot: LumaCore.ThreadSnapshot?
    @State private var loadError: String?
    @State private var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            content
        }
        .detailPaneInset(.leading)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: thread.id) {
            await reload()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(thread.name ?? "tid \(thread.id)")
                .font(.headline)
            if let snap = snapshot {
                Text(snap.state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)

            let actions = engine.threadActions(sessionID: sessionID, thread: thread)
            if !actions.isEmpty {
                Menu {
                    ForEach(actions) { action in
                        Button(role: action.role == .destructive ? .destructive : nil) {
                            Task { @MainActor in
                                if let target = await action.perform() {
                                    selection = SidebarItemID(navigationTarget: target)
                                }
                            }
                        } label: {
                            if let icon = action.systemImage {
                                Label(action.title, systemImage: icon)
                            } else {
                                Text(action.title)
                            }
                        }
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            Text(loadError).foregroundStyle(.red)
        } else if let snap = snapshot {
            if let entry = thread.entrypoint {
                Text("Entry: \(String(format: "0x%llx", entry.routine))")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .leading)],
                    alignment: .leading,
                    spacing: 4
                ) {
                    ForEach(snap.registers) { reg in
                        registerCell(reg)
                    }
                }
                .padding(.top, 4)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func registerCell(_ reg: LumaCore.ThreadSnapshot.Register) -> some View {
        HStack(spacing: 6) {
            Text(reg.name)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            registerValue(reg)
            Spacer(minLength: 0)
        }
        .font(.system(.body, design: .monospaced))
    }

    @ViewBuilder
    private func registerValue(_ reg: LumaCore.ThreadSnapshot.Register) -> some View {
        if let address = reg.pointerValue {
            Text(reg.rawValue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                .pointerActions(
                    engine: engine,
                    sessionID: sessionID,
                    value: reg.rawValue,
                    address: address,
                    context: AddressContext(kind: registerKind(reg)),
                    selection: $selection
                )
        } else {
            Text(reg.rawValue)
                .textSelection(.enabled)
        }
    }

    private func registerKind(_ reg: LumaCore.ThreadSnapshot.Register) -> AddressContext.Kind {
        let n = reg.name
        if n == "pc" || n == "rip" || n == "eip" {
            return .code
        }
        return .unspecified
    }

    private func reload() async {
        guard let node = engine.node(forSessionID: sessionID) else {
            loadError = "Process is detached."
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            snapshot = try await node.fetchThreadSnapshot(id: thread.id)
            if snapshot == nil {
                loadError = "Thread no longer exists."
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}
