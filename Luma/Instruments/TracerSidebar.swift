import LumaCore
import SwiftUI

enum TracerSidebar {
    static let inlineLimit = 5
}

struct TracerSidebarChildren: View {
    let sessionID: UUID
    let instance: LumaCore.InstrumentInstance
    let engine: Engine
    @Binding var selection: SidebarItemID?

    var body: some View {
        if let config = try? TracerConfig.decode(from: instance.configJSON) {
            let ordered = config.hooksByMostRecentlyEdited()
            let inline = inlineHooks(from: ordered)
            ForEach(inline, id: \.id) { hook in
                TracerSidebarHookRow(
                    hook: hook,
                    engine: engine,
                    sessionID: sessionID,
                    instrumentID: instance.id,
                    selection: $selection
                )
                .tag(SidebarItemID.instrumentComponent(sessionID, instance.id, hook.id))
            }
            if ordered.count > inline.count {
                TracerSidebarBrowseAllRow(
                    sessionID: sessionID,
                    instance: instance,
                    hooks: ordered,
                    selection: $selection
                )
            }
        }
    }

    private func inlineHooks(from ordered: [TracerConfig.Hook]) -> [TracerConfig.Hook] {
        var inline = Array(ordered.prefix(TracerSidebar.inlineLimit))
        if let selectedID = selectedHookIDInThisInstrument,
            !inline.contains(where: { $0.id == selectedID }),
            let selected = ordered.first(where: { $0.id == selectedID })
        {
            if inline.count >= TracerSidebar.inlineLimit {
                inline.removeLast()
            }
            inline.append(selected)
        }
        return inline.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var selectedHookIDInThisInstrument: UUID? {
        guard case .instrumentComponent(_, let iid, let hookID) = selection,
            iid == instance.id
        else { return nil }
        return hookID
    }
}

private struct TracerSidebarHookRow: View {
    let hook: TracerConfig.Hook
    let engine: Engine
    let sessionID: UUID
    let instrumentID: UUID
    @Binding var selection: SidebarItemID?

    @State private var isShowingITraceConfig = false
    @State private var isShowingDeleteConfirm = false
    @State private var draftMaxInvocations: Int = ITraceArming.defaultMaxInvocations
    @State private var draftMaxBytes: Int = ITraceArming.defaultMaxBytesPerInvocation

    var body: some View {
        HStack(spacing: 6) {
            hookIcon
                .frame(width: 16, alignment: .center)
                .foregroundStyle(.secondary)
            Text(hook.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, sidebarGrandchildIndent)
        .opacity(hook.state == .enabled ? 1 : 0.5)
        .help(hook.addressAnchor.displayString)
        .contextMenu {
            Button {
                toggleEnabled()
            } label: {
                Label(
                    hook.state == .enabled ? "Disable Hook" : "Enable Hook",
                    systemImage: hook.state == .enabled ? "pause.circle" : "play.circle"
                )
            }

            if hook.kind == .function {
                Divider()
                if hook.itraceArming != nil {
                    Button {
                        applyITraceArming(nil)
                    } label: {
                        Label("Disable Instruction Trace", systemImage: "scope")
                    }
                    Button {
                        seedITraceDrafts()
                        isShowingITraceConfig = true
                    } label: {
                        Label("Edit Instruction Trace\u{2026}", systemImage: "slider.horizontal.3")
                    }
                } else {
                    Button {
                        seedITraceDrafts()
                        isShowingITraceConfig = true
                    } label: {
                        Label("Enable Instruction Trace\u{2026}", systemImage: "scope")
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                isShowingDeleteConfirm = true
            } label: {
                Label("Delete Hook", systemImage: "trash")
            }
        }
        .popover(isPresented: $isShowingITraceConfig, arrowEdge: .trailing) {
            ITracePopover(
                captured: itraceCaptured,
                isOn: hook.itraceArming != nil,
                draftMaxInvocations: $draftMaxInvocations,
                draftMaxBytes: $draftMaxBytes,
                onEnable: {
                    applyITraceArming(
                        ITraceArming(
                            maxInvocations: draftMaxInvocations,
                            maxBytesPerInvocation: draftMaxBytes
                        )
                    )
                    isShowingITraceConfig = false
                },
                onDisable: {
                    applyITraceArming(nil)
                    isShowingITraceConfig = false
                }
            )
        }
        .confirmationDialog(
            "Delete \"\(hook.displayName)\"?",
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Hook", role: .destructive) { deleteHook() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the hook from the tracer.")
        }
    }

    @ViewBuilder
    private var hookIcon: some View {
        switch hook.kind {
        case .function:
            Image(systemName: "f.cursive")
                .font(.system(size: 12, weight: .medium))
        case .instruction:
            Text("i")
                .font(.system(size: 14, weight: .regular, design: .serif).italic())
        }
    }

    private var itraceCaptured: Int {
        let traces = engine.tracesBySession[sessionID] ?? []
        return traces.reduce(into: 0) { count, trace in
            if case .functionCall(let id, _) = trace.origin, id == hook.id { count += 1 }
        }
    }

    private func seedITraceDrafts() {
        let seed = hook.itraceArming ?? ITraceArming()
        draftMaxInvocations = seed.maxInvocations
        draftMaxBytes = seed.maxBytesPerInvocation
    }

    private func toggleEnabled() {
        let newState: TracerConfig.Hook.State = hook.state == .enabled ? .disabled : .enabled
        Task { @MainActor in
            await engine.updateTracerHook(sessionID: sessionID, hookID: hook.id) { hook in
                hook.state = newState
            }
        }
    }

    private func applyITraceArming(_ arming: ITraceArming?) {
        Task { @MainActor in
            await engine.updateTracerHook(sessionID: sessionID, hookID: hook.id) { hook in
                hook.itraceArming = arming
            }
        }
    }

    private func deleteHook() {
        let wasSelected = selection == .instrumentComponent(sessionID, instrumentID, hook.id)
        let hookID = hook.id
        Task { @MainActor in
            await engine.removeTracerHook(sessionID: sessionID, hookID: hookID)
            if wasSelected {
                selection = .instrument(sessionID, instrumentID)
            }
        }
    }
}

private struct TracerSidebarBrowseAllRow: View {
    let sessionID: UUID
    let instance: LumaCore.InstrumentInstance
    let hooks: [TracerConfig.Hook]
    @Binding var selection: SidebarItemID?

    @State private var isShowingBrowser = false

    var body: some View {
        Button {
            isShowingBrowser = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(.secondary)
                Text("Browse all \(hooks.count)\u{2026}")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, sidebarGrandchildIndent)
        .popover(isPresented: $isShowingBrowser, arrowEdge: .trailing) {
            TracerHookBrowserPopover(
                sessionID: sessionID,
                instanceID: instance.id,
                hooks: hooks,
                selection: $selection,
                onDismiss: { isShowingBrowser = false }
            )
        }
    }
}
