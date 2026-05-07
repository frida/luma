import LumaCore
import SwiftUI

enum SessionDetailSection: String, CaseIterable, Identifiable, Codable {
    case summary = "Summary"
    case modules = "Modules"
    case threads = "Threads"

    var id: String { rawValue }
}

struct SessionDetailView: View {
    let sessionID: UUID
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    private var section: Binding<SessionDetailSection> {
        Binding(
            get: { workspace.sessionDetailSection(for: sessionID) },
            set: { workspace.setSessionDetailSection(sessionID: sessionID, section: $0) }
        )
    }

    private var selectedModuleID: Binding<ProcessModule.ID?> {
        Binding(
            get: { workspace.lastSelectedModuleID(for: sessionID) },
            set: { workspace.setLastSelectedModuleID(sessionID: sessionID, moduleID: $0) }
        )
    }

    private var selectedThreadID: Binding<ProcessThread.ID?> {
        Binding(
            get: { workspace.lastSelectedThreadID(for: sessionID) },
            set: { workspace.setLastSelectedThreadID(sessionID: sessionID, threadID: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sectionPicker
            Divider()
            sectionContent
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var session: LumaCore.ProcessSession? {
        workspace.engine.session(id: sessionID)
    }

    private var node: LumaCore.ProcessNode? {
        workspace.engine.node(forSessionID: sessionID)
    }

    private var header: some View {
        Text(node?.processName ?? session?.processName ?? "Session")
            .font(.title2).bold()
    }

    private var sectionPicker: some View {
        Picker("", selection: section) {
            ForEach(SessionDetailSection.allCases) { s in
                Text(label(for: s)).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func label(for section: SessionDetailSection) -> String {
        switch section {
        case .summary: return "Summary"
        case .modules: return "Modules (\(node?.modules.count ?? 0))"
        case .threads: return "Threads (\(displayedThreads.count))"
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section.wrappedValue {
        case .summary: summaryContent
        case .modules: modulesContent
        case .threads: threadsContent
        }
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
            if let info = node?.processInfo {
                row("Platform", info.platform)
                row("Architecture", info.arch)
                row("Pointer size", "\(info.pointerSize) bytes")
            } else if let info = session?.processInfo {
                row("Platform", info.platform)
                row("Architecture", info.arch)
                row("Pointer size", "\(info.pointerSize) bytes")
            }
            if let main = node?.mainModule {
                row("Main module", main.name)
                row("Path", main.path)
                row("Base", String(format: "0x%llx", main.base))
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

    private var modulesContent: some View {
        let modules = (node?.modules ?? []).sorted(by: { $0.base < $1.base })
        return PlatformHSplit {
            modulesTable(modules)
                .frame(minWidth: 240, idealWidth: 360)

            if let module = currentSelectedModule {
                ModuleDetailView(
                    sessionID: sessionID,
                    module: module,
                    workspace: workspace,
                    selection: $selection
                )
                .id(module.id)
                .frame(minWidth: 360)
            } else {
                placeholder("Select a module")
                    .frame(minWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func modulesTable(_ modules: [ProcessModule]) -> some View {
        Group {
            if modules.isEmpty {
                placeholder("No modules loaded")
            } else {
                Table(modules, selection: selectedModuleID) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Base") { m in
                        Text(String(format: "0x%llx", m.base))
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Size") { m in
                        Text(String(format: "0x%llx", m.size))
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
    }

    private var currentSelectedModule: ProcessModule? {
        guard let id = selectedModuleID.wrappedValue else { return nil }
        return node?.modules.first(where: { $0.id == id })
    }

    private var displayedThreads: [ProcessThread] {
        let live = node?.threads ?? []
        let source = live.isEmpty ? (session?.lastKnownThreads ?? []) : live
        return source.sorted(by: { $0.id < $1.id })
    }

    private var threadsContent: some View {
        let threads = displayedThreads
        return PlatformHSplit {
            threadsTable(threads)
                .frame(minWidth: 240, idealWidth: 320)

            if let thread = currentSelectedThread {
                ThreadDetailView(
                    sessionID: sessionID,
                    thread: thread,
                    workspace: workspace,
                    selection: $selection
                )
                .id(thread.id)
                .frame(minWidth: 360)
            } else {
                placeholder("Select a thread")
                    .frame(minWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func threadsTable(_ threads: [ProcessThread]) -> some View {
        Group {
            if threads.isEmpty {
                placeholder("No threads observed")
            } else {
                Table(threads, selection: selectedThreadID) {
                    TableColumn("ID") { t in Text(String(t.id)) }
                    TableColumn("Name") { t in Text(t.name ?? "—") }
                    TableColumn("Entrypoint") { t in
                        Text(t.entrypoint.map { String(format: "0x%llx", $0.routine) } ?? "—")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .contextMenu(forSelectionType: ProcessThread.ID.self) { ids in
                    if let id = ids.first, let thread = threads.first(where: { $0.id == id }) {
                        threadActionsMenu(for: thread)
                    }
                }
            }
        }
    }

    private var currentSelectedThread: ProcessThread? {
        guard let id = selectedThreadID.wrappedValue else { return nil }
        return displayedThreads.first(where: { $0.id == id })
    }

    @ViewBuilder
    private func threadActionsMenu(for thread: ProcessThread) -> some View {
        let actions = workspace.engine.threadActions(sessionID: sessionID, thread: thread)
        ForEach(actions) { action in
            Button(role: action.role == .destructive ? .destructive : nil) {
                Task { @MainActor in
                    if let target = await action.perform() {
                        selection = workspace.sidebarItem(for: target)
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
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
