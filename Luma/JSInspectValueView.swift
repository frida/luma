import Combine
import SwiftUI

struct JSInspectValueView: View {
    let value: JSInspectValue

    let sessionID: UUID
    let workspace: Workspace
    let selection: Binding<SidebarItemID?>

    private let circularTargets: Set<Int>

    @StateObject private var anchorStore = CircularAnchorStore()

    init(
        value: JSInspectValue,
        sessionID: UUID,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) {
        self.value = value

        self.sessionID = sessionID
        self.workspace = workspace
        self.selection = selection

        self.circularTargets = JSInspectValueView.collectCircularTargets(in: value)
    }

    var body: some View {
        JSInspectNodeView(
            value: value,
            isRoot: true,
            sessionID: sessionID,
            workspace: workspace,
            selection: selection
        )
        .environment(\.circularTargets, circularTargets)
        .environmentObject(anchorStore)
        .font(.system(.footnote, design: .monospaced))
        .textSelection(.enabled)
        .errorPopoverHost()
    }

    private static func collectCircularTargets(in value: JSInspectValue) -> Set<Int> {
        var ids = Set<Int>()

        func walk(_ v: JSInspectValue) {
            switch v {
            case .object(_, let props):
                for p in props {
                    walk(p.key)
                    walk(p.value)
                }
            case .array(_, let elements):
                for e in elements { walk(e) }
            case .map(_, let entries):
                for e in entries {
                    walk(e.key)
                    walk(e.value)
                }
            case .set(_, let elements):
                for e in elements { walk(e) }
            case .circular(let id):
                ids.insert(id)
            default:
                break
            }
        }

        walk(value)
        return ids
    }
}

private struct JSInspectNodeView: View {
    let value: JSInspectValue
    let isRoot: Bool

    let sessionID: UUID
    let workspace: Workspace
    let selection: Binding<SidebarItemID?>

    @State private var isExpanded: Bool = true
    @State private var childLimit: Int = 50

    @Environment(\.errorPresenter) private var errorPresenter
    @Environment(\.circularTargets) private var circularTargets
    @EnvironmentObject private var anchorStore: CircularAnchorStore

    var body: some View {
        switch value {
        case .object(_, let props):
            objectView(props)

        case .array(_, let elements):
            arrayView(elements)

        case .map(_, let entries):
            mapView(entries)

        case .set(_, let elements):
            setView(elements)

        default:
            leafView(value)
        }
    }

    private func objectView(_ props: [JSInspectValue.Property]) -> some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<min(props.count, childLimit), id: \.self) { idx in
                        let prop = props[idx]
                        HStack(alignment: .top, spacing: 4) {
                            Text(prop.displayKey + ":")
                                .foregroundStyle(.green)

                            JSInspectNodeView(
                                value: prop.value,
                                isRoot: false,
                                sessionID: sessionID,
                                workspace: workspace,
                                selection: selection
                            )
                        }
                    }

                    if props.count > childLimit {
                        Button("Show all \(props.count) properties…") {
                            childLimit = props.count
                        }
                        platformLinkButtonStyle()
                    }
                }
                .padding(.leading, 12)
            },
            label: {
                HStack(spacing: 4) {
                    Text("Object{\(props.count)}\(anchorSuffix())")
                        .foregroundStyle(.cyan)
                    if let preview = inlinePreview(value) {
                        Text(preview)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        )
    }

    private func arrayView(_ elements: [JSInspectValue]) -> some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<min(elements.count, childLimit), id: \.self) { idx in
                        HStack(alignment: .top, spacing: 4) {
                            Text("[\(idx)]")
                                .foregroundStyle(.secondary)

                            JSInspectNodeView(
                                value: elements[idx],
                                isRoot: false,
                                sessionID: sessionID,
                                workspace: workspace,
                                selection: selection
                            )
                        }
                    }

                    if elements.count > childLimit {
                        Button("Show all \(elements.count) items…") {
                            childLimit = elements.count
                        }
                        platformLinkButtonStyle()
                    }
                }
                .padding(.leading, 12)
            },
            label: {
                HStack(spacing: 4) {
                    Text("Array[\(elements.count)]\(anchorSuffix())")
                        .foregroundStyle(.cyan)
                    if let preview = inlinePreview(value) {
                        Text(preview)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        )
    }

    private func mapView(_ entries: [JSInspectValue.Property]) -> some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<min(entries.count, childLimit), id: \.self) { idx in
                        let entry = entries[idx]
                        HStack(alignment: .top, spacing: 4) {
                            JSInspectNodeView(
                                value: entry.key,
                                isRoot: false,
                                sessionID: sessionID,
                                workspace: workspace,
                                selection: selection
                            )
                            .foregroundStyle(.green)

                            Text("→")
                                .foregroundStyle(.secondary)

                            JSInspectNodeView(
                                value: entry.value,
                                isRoot: false,
                                sessionID: sessionID,
                                workspace: workspace,
                                selection: selection
                            )
                        }
                    }

                    if entries.count > childLimit {
                        Button("Show all \(entries.count) entries…") {
                            childLimit = entries.count
                        }
                        platformLinkButtonStyle()
                    }
                }
                .padding(.leading, 12)
            },
            label: {
                HStack(spacing: 4) {
                    Text("Map{\(entries.count)}\(anchorSuffix())")
                        .foregroundStyle(.cyan)
                    if let preview = inlinePreview(value) {
                        Text(preview)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        )
    }

    private func setView(_ elements: [JSInspectValue]) -> some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<min(elements.count, childLimit), id: \.self) { idx in
                        HStack(alignment: .top, spacing: 4) {
                            Text("•")
                                .foregroundStyle(.secondary)

                            JSInspectNodeView(
                                value: elements[idx],
                                isRoot: false,
                                sessionID: sessionID,
                                workspace: workspace,
                                selection: selection
                            )
                        }
                    }

                    if elements.count > childLimit {
                        Button("Show all \(elements.count) items…") {
                            childLimit = elements.count
                        }
                        platformLinkButtonStyle()
                    }
                }
                .padding(.leading, 12)
            },
            label: {
                HStack(spacing: 4) {
                    Text("Set{\(elements.count)}\(anchorSuffix())")
                        .foregroundStyle(.cyan)
                    if let preview = inlinePreview(value) {
                        Text(preview)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func leafView(_ value: JSInspectValue) -> some View {
        switch value {
        case .bytes(let bytes):
            VStack(alignment: .leading, spacing: 4) {
                Text("Bytes(\(bytes.kind.rawValue)[\(bytes.data.count)])")
                    .foregroundStyle(.mint)
                HexView(data: bytes.data)
            }

        default:
            if case .nativePointer = value,
                let addr = value.nativePointerAddress
            {
                Text(value.prettyAttributedDescription())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
                    .contextMenu {
                        Button {
                            Task { @MainActor in
                                do {
                                    let insight = try workspace.getOrCreateInsight(
                                        sessionID: sessionID,
                                        pointer: addr,
                                        kind: .memory
                                    )
                                    selection.wrappedValue = .insight(sessionID, insight.id)
                                } catch {
                                    errorPresenter.present("Can’t open memory", error.localizedDescription)
                                }
                            }
                        } label: {
                            Label("Open Memory", systemImage: "doc.text.magnifyingglass")
                        }

                        Button {
                            Task { @MainActor in
                                do {
                                    let insight = try workspace.getOrCreateInsight(
                                        sessionID: sessionID,
                                        pointer: addr,
                                        kind: .disassembly
                                    )
                                    selection.wrappedValue = .insight(sessionID, insight.id)
                                } catch {
                                    errorPresenter.present("Can’t open disassembly", error.localizedDescription)
                                }
                            }
                        } label: {
                            Label("Open Disassembly", systemImage: "hammer")
                        }
                    }
            } else {
                Text(value.prettyAttributedDescription())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func containerId() -> Int? {
        switch value {
        case .object(let id, _),
            .array(let id, _),
            .map(let id, _),
            .set(let id, _):
            return id
        default:
            return nil
        }
    }

    private func anchorSuffix() -> String {
        guard let id = containerId() else { return "" }
        guard circularTargets.contains(id) else { return "" }
        if !anchorStore.anchoredIds.contains(id) {
            anchorStore.anchoredIds.insert(id)
            return " *\(id)"
        }
        return ""
    }

    private func inlinePreview(_ value: JSInspectValue) -> String? {
        switch value {
        case .object(_, let props):
            let preview =
                props.prefix(3)
                .map { "\($0.displayKey): \($0.value.inlineDescription)" }
                .joined(separator: ", ")
            return props.isEmpty ? nil : "{\(preview)\(props.count > 3 ? ", …" : "")}"

        case .array(_, let elements):
            let preview =
                elements.prefix(3)
                .map { $0.inlineDescription }
                .joined(separator: ", ")
            return elements.isEmpty ? nil : "[\(preview)\(elements.count > 3 ? ", …" : "")]"

        case .map(_, let entries):
            let preview =
                entries.prefix(3)
                .map { "\($0.key.inlineDescription) => \($0.value.inlineDescription)" }
                .joined(separator: ", ")
            return entries.isEmpty ? nil : "{\(preview)\(entries.count > 3 ? ", …" : "")}"

        case .set(_, let elements):
            let preview =
                elements.prefix(3)
                .map { $0.inlineDescription }
                .joined(separator: ", ")
            return elements.isEmpty ? nil : "{\(preview)\(elements.count > 3 ? ", …" : "")}"

        default:
            return nil
        }
    }
}

private final class CircularAnchorStore: ObservableObject {
    @Published var anchoredIds: Set<Int> = []
}

extension EnvironmentValues {
    var circularTargets: Set<Int> {
        get { self[CircularTargetsKey.self] }
        set { self[CircularTargetsKey.self] = newValue }
    }
}

private struct CircularTargetsKey: EnvironmentKey {
    static let defaultValue: Set<Int> = []
}
