import SwiftData
import SwiftUI
import SwiftyR2

struct AddressInsightDetailView: View {
    @Bindable var session: ProcessSession
    @Bindable var insight: AddressInsight
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var refreshTask: Task<Void, Never>?
    @State private var output: AttributedString = AttributedString("")
    @State private var errorText: AttributedString?

    private var node: ProcessNode? {
        workspace.processNodes.first { $0.sessionRecord == session }
    }

    var body: some View {
        VStack(spacing: 0) {
            if node == nil {
                SessionDetachedBanner(session: session, workspace: workspace)
            }

            header
            Divider()

            ScrollView {
                Text(errorText ?? output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding()
            }
        }
        .onAppear { refresh() }
        .onChange(of: insight.kind) { refresh() }
        .onChange(of: insight.byteCount) { refresh() }
        .onChange(of: session.phase) { refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title).font(.headline)
                Text(insight.anchor.displayString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $insight.kind) {
                Text("Memory").tag(AddressInsight.Kind.memory)
                Text("Disassembly").tag(AddressInsight.Kind.disassembly)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            if insight.kind == .memory {
                Stepper("", value: $insight.byteCount, in: 0x40...0x4000, step: 0x40)
                    .labelsHidden()
                    .help("Change dump size")
            }

            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .disabled(node == nil)
        }
        .padding()
        .background(.bar)
    }

    private func refresh() {
        errorText = nil
        output = AttributedString("")

        guard let node else {
            errorText = AttributedString("Session detached.")
            return
        }

        guard let resolved = node.resolve(insight.anchor) else {
            errorText = AttributedString("Could not resolve \(insight.anchor.displayString) in the current process.")
            return
        }

        insight.lastResolvedAddress = resolved

        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            guard let node = workspace.processNodes.first(where: { $0.sessionRecord == session }) else {
                errorText = AttributedString("Session detached.")
                return
            }

            guard let resolved = node.resolve(insight.anchor) else {
                errorText = AttributedString("Could not resolve \(insight.anchor.displayString) in the current process.")
                return
            }

            insight.lastResolvedAddress = resolved

            switch insight.kind {
            case .memory:
                let out = await node.r2Cmd("px \(insight.byteCount) @ 0x\(String(resolved, radix: 16))")
                guard !Task.isCancelled else { return }
                output = try! parseAnsi(out)

            case .disassembly:
                let out = await node.r2Cmd("pd 64 @ 0x\(String(resolved, radix: 16))")
                guard !Task.isCancelled else { return }
                output = try! parseAnsi(out)
            }
        }
    }
}
