import LumaCore
import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @Environment(\.errorPresenter) private var errorPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            summaryContent
        }
        .detailPaneInset()
        .padding(.vertical, 16)
    }

    private var session: LumaCore.ProcessSession? {
        engine.session(id: sessionID)
    }

    private var node: LumaCore.ProcessNode? {
        engine.node(forSessionID: sessionID)
    }

    private var header: some View {
        Text(node?.processName ?? session?.processName ?? "Session")
            .font(.title2).bold()
    }

    private var summaryContent: some View {
        ScrollView {
            summaryGrid
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summaryGrid: some View {
        let session = session
        let node = node
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
            row("Status", statusText(session: session, node: node))
            row("Device", node?.deviceName ?? session?.deviceName ?? "—")
            row("PID", String(node?.pid ?? session?.lastKnownPID ?? 0))
            if let info = session?.processInfo {
                row("Platform", info.platform)
                row("Architecture", info.arch)
                row("Pointer size", "\(info.pointerSize) bytes")
            }
            if let main = session?.lastKnownMainModule {
                row("Main module", main.name)
                row("Path", main.path)
                baseRow(address: main.base)
                row("Size", "\(main.size) bytes")
            }
        }
        .font(.system(.body, design: .monospaced))
    }

    private func statusText(session: LumaCore.ProcessSession?, node: LumaCore.ProcessNode?) -> String {
        if let node {
            switch node.phase {
            case .attaching: return "Attaching…"
            case .attached: return "Attached"
            case .detached: return "Detached"
            }
        }
        switch session?.phase {
        case .attaching: return "Attaching…"
        case .awaitingInitialResume: return "Awaiting initial resume"
        case .attached: return "Attached"
        case .idle, .none: return "Idle"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func baseRow(address: UInt64) -> some View {
        GridRow {
            Text("Base")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            PointerValueText(
                engine: engine,
                sessionID: sessionID,
                value: String(format: "0x%llx", address),
                address: address,
                selection: $selection
            )
        }
    }
}
