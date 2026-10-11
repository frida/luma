import LumaCore
import SwiftUI

struct SwiftTypeView: View {
    let sessionID: UUID
    let module: LumaCore.ProcessModule
    let type: SwiftTypeSummary
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var typeDescription: SwiftTypeDescription?
    @State private var loadError: String?
    @State private var facts: [UInt64: AddressFacts] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .detailPaneInset(.horizontal)
            content
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: type) {
            await load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(type.kind.rawValue)
                    .foregroundStyle(.secondary)
                Text(type.displayName(inModule: module.name))
                    .fontWeight(.semibold)
            }
            .font(.headline)
            if let typeDescription, !typeDescription.inheritance.isEmpty {
                Text(typeDescription.inheritance.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            Text(loadError)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let typeDescription {
            List {
                if !typeDescription.members.isEmpty {
                    Section("Members") {
                        ForEach(typeDescription.members, id: \.self, content: memberRow)
                    }
                }
                if !typeDescription.conformers.isEmpty {
                    Section("Conforming Types") {
                        ForEach(typeDescription.conformers, id: \.self) { name in
                            Text(name).textSelection(.enabled)
                        }
                    }
                }
                Section("Functions") {
                    ForEach(typeDescription.functions, id: \.self, content: functionRow)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func memberRow(_ member: SwiftTypeDescription.Member) -> some View {
        HStack(spacing: 8) {
            Text(member.name)
            if let typeName = member.typeName {
                Text(typeName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(member.role.title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func functionRow(_ function: SwiftTypeDescription.Function) -> some View {
        let context = AddressContext(kind: .function, anchorHint: function.anchor)
        return HStack(spacing: 8) {
            Text(function.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(function.name)
            Spacer()
            Text(String(format: "0x%llx", function.address))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard hovering, facts[function.address] == nil else { return }
            Task {
                facts[function.address] = await engine.addressFacts(
                    sessionID: sessionID, address: function.address, context: context)
            }
        }
        .contextMenu {
            AddressMenuItems(
                engine: engine,
                sessionID: sessionID,
                value: String(format: "0x%llx", function.address),
                address: function.address,
                context: context,
                copyTitle: "Copy Address",
                facts: facts[function.address],
                selection: $selection
            ) {
                EmptyView()
            }
        }
    }

    private func load() async {
        guard let node = engine.node(forSessionID: sessionID) else {
            loadError = "Process is detached."
            return
        }
        do {
            typeDescription = try await node.describeSwiftType(module: module.name, type: type)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
