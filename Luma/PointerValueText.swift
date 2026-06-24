import LumaCore
import SwiftUI

struct PointerValueText: View {
    let engine: Engine
    let sessionID: UUID
    let value: String
    let address: UInt64
    var context: AddressContext = AddressContext()
    @Binding var selection: SidebarItemID?

    var body: some View {
        Text(value)
            .font(.system(.body, design: .monospaced))
            .pointerActions(
                engine: engine,
                sessionID: sessionID,
                value: value,
                address: address,
                context: context,
                selection: $selection
            )
    }
}

extension View {
    func pointerActions<Extra: View>(
        engine: Engine,
        sessionID: UUID,
        value: String,
        address: UInt64,
        context: AddressContext = AddressContext(),
        selection: Binding<SidebarItemID?>,
        @ViewBuilder extraItems: @escaping () -> Extra = { EmptyView() }
    ) -> some View {
        modifier(
            PointerActions(
                engine: engine,
                sessionID: sessionID,
                value: value,
                address: address,
                context: context,
                selection: selection,
                extraItems: extraItems
            )
        )
    }
}

private struct PointerActions<Extra: View>: ViewModifier {
    let engine: Engine
    let sessionID: UUID
    let value: String
    let address: UInt64
    let context: AddressContext
    @Binding var selection: SidebarItemID?
    @ViewBuilder let extraItems: () -> Extra

    @State private var facts: AddressFacts?

    func body(content: Content) -> some View {
        content
            .textSelection(.disabled)
            .onHover { hovering in
                guard hovering, facts == nil else { return }
                Task { facts = await engine.addressFacts(sessionID: sessionID, address: address, context: context) }
            }
            .contextMenu { menu }
    }

    private var factsKey: FactsKey {
        FactsKey(address: address, attached: engine.node(forSessionID: sessionID) != nil)
    }

    private struct FactsKey: Equatable {
        let address: UInt64
        let attached: Bool
    }

    @ViewBuilder private var menu: some View {
        Button {
            Platform.copyToClipboard(value)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        if let facts {
            if facts.mapping == .executable {
                inspectorButton("Open Disassembly", systemImage: "hammer", kind: .disassembly)
            }
            if facts.mapping != .unmapped {
                inspectorButton("Open Memory", systemImage: "doc.text.magnifyingglass", kind: .memory)
            }

            let actions = engine.addressActions(sessionID: sessionID, address: address, context: context, facts: facts)
            if !actions.isEmpty {
                Divider()
                ForEach(actions) { action in
                    actionButton(action)
                }
            }
        } else {
            Divider()
            Button {} label: {
                Label("Analyzing\u{2026}", systemImage: "hourglass")
            }
            .disabled(true)
        }

        extraItems()
    }

    private func inspectorButton(_ title: String, systemImage: String, kind: LumaCore.AddressInsight.Kind) -> some View {
        Button {
            openInsight(kind: kind)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func actionButton(_ action: AddressAction) -> some View {
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

    private func openInsight(kind: LumaCore.AddressInsight.Kind) {
        Task { @MainActor in
            guard let insight = try? engine.getOrCreateInsight(
                sessionID: sessionID,
                pointer: address,
                kind: kind,
                preferredAnchor: context.anchorHint
            ) else { return }
            selection = .insight(sessionID, insight.id)
        }
    }
}
