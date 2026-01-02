import SwiftUI

struct TracerEventRowView: View {
    let messageView: AnyView
    let process: ProcessNode
    let backtrace: [JSInspectValue]?
    let workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var showBacktracePopover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            messageView

            if let backtrace, !backtrace.isEmpty {
                Spacer(minLength: 0)

                Button {
                    showBacktracePopover.toggle()
                } label: {
                    Text("Backtrace")
                        .font(.system(.footnote, design: .monospaced))
                        .hidden()
                        .overlay {
                            Image(systemName: "list.bullet.rectangle")
                                .imageScale(.small)
                        }
                }
                .buttonStyle(.borderless)
                .help("Show backtrace")
                .popover(isPresented: $showBacktracePopover, arrowEdge: .bottom) {
                    TracerBacktraceView(
                        process: process,
                        pointers: backtrace,
                        workspace: workspace,
                        selection: $selection
                    )
                    .frame(minWidth: 520, minHeight: 280)
                    .padding()
                }
            }
        }
    }
}

private struct TracerBacktraceView: View {
    let process: ProcessNode
    let pointers: [JSInspectValue]
    let workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var symbols: [ProcessNode.SymbolicateResult] = []
    @State private var isLoading = false
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Backtrace")
                    .font(.headline)

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if lastError != nil {
                    Button("Symbolicate") {
                        Task { await symbolicate() }
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(pointers.enumerated()), id: \.offset) { idx, ptrValue in
                        let addr = ptrValue.nativePointerAddress ?? 0
                        let anchor = process.anchor(for: addr)

                        HStack(alignment: .center, spacing: 8) {
                            Text("#\(idx + 1)")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(displayString(idx: idx, anchor: anchor))
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)

                            Spacer(minLength: 0)

                            Button {
                                openDisassembly(at: addr)
                            } label: {
                                Image(systemName: "arrow.right.circle")
                                    .imageScale(.small)
                                    .padding(4)
                            }
                            .buttonStyle(.borderless)
                            .help("Open Disassembly")
                        }
                        .padding(.vertical, 4)

                        Divider()
                    }
                }
            }
        }
        .task {
            await symbolicate()
        }
    }

    private func displayString(
        idx: Int,
        anchor: AddressAnchor
    ) -> String {
        guard idx < symbols.count else {
            return anchor.displayString
        }

        switch symbols[idx] {
        case .failure:
            return anchor.displayString

        case .module(let moduleName, let name):
            return "\(moduleName)!\(name)"

        case .file(let moduleName, let name, let fileName, let lineNumber):
            return "\(moduleName)!\(name) — \(fileName):\(lineNumber)"

        case .fileColumn(let moduleName, let name, let fileName, let lineNumber, let column):
            return "\(moduleName)!\(name) — \(fileName):\(lineNumber):\(column)"
        }
    }

    private func openDisassembly(at address: UInt64) {
        do {
            let insight = try workspace.getOrCreateInsight(
                sessionID: process.sessionRecord.id,
                pointer: address,
                kind: .disassembly
            )
            selection = .insight(process.sessionRecord.id, insight.id)
        } catch {
            lastError = "Can’t open disassembly: \(error.localizedDescription)"
        }
    }

    private func symbolicate() async {
        if isLoading { return }
        isLoading = true
        lastError = nil

        do {
            symbols = try await process.symbolicate(addresses: pointers.compactMap { $0.nativePointerAddress })
        } catch {
            lastError = "Symbolication failed: \(error)"
        }

        isLoading = false
    }
}
