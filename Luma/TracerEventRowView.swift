import SwiftUI
import LumaCore

struct TracerEventRowView: View {
    let messageView: AnyView
    let sessionID: UUID?
    let backtrace: [JSInspectValue]?
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var showBacktracePopover = false

    @Environment(\.pauseEventStream) private var pauseEventStream

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            messageView

            if let sessionID, let backtrace, !backtrace.isEmpty {
                Spacer(minLength: 0)

                Button {
                    if !showBacktracePopover {
                        pauseEventStream()
                    }
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
                        sessionID: sessionID,
                        pointers: backtrace,
                        engine: engine,
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
    let sessionID: UUID
    let pointers: [JSInspectValue]
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var symbols: [SymbolDisplay] = []
    @State private var isLoading = false

    @Environment(\.errorPresenter) private var errorPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Backtrace")
                    .font(.headline)

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(pointers.enumerated()), id: \.offset) { idx, ptrValue in
                        let addr = ptrValue.nativePointerAddress ?? 0

                        HStack(alignment: .center, spacing: 8) {
                            Text("#\(idx + 1)")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(displayString(idx: idx, address: addr))
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

    private func displayString(idx: Int, address: UInt64) -> String {
        if idx < symbols.count {
            return symbols[idx].displayString
        }
        return engine.anchor(sessionID: sessionID, address: address).displayString
    }

    private func openDisassembly(at address: UInt64) {
        do {
            let insight = try engine.getOrCreateInsight(
                sessionID: sessionID,
                pointer: address,
                kind: .disassembly
            )
            selection = .insight(sessionID, insight.id)
        } catch {
            errorPresenter.present("Can’t open disassembly", error.localizedDescription)
        }
    }

    private func symbolicate() async {
        if isLoading { return }
        isLoading = true
        symbols = await engine.symbolDisplay(sessionID: sessionID, addresses: pointers.map { $0.nativePointerAddress ?? 0 })
        isLoading = false
    }
}
