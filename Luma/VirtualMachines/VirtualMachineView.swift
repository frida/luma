import LumaCore
import SwiftUI

#if canImport(AppKit)

struct VirtualMachineView: View {
    let engine: Engine
    let record: VirtualMachineRecord
    let presentation: VirtualMachinePresentation
    let logHeight: CGFloat?

    var body: some View {
        LogBehindScreenLayout(logHeight: logHeight) {
            if let console {
                VirtualMachineLog(console: console, isShown: isShowingLog)
                    .opacity(isShowingLog ? 1 : 0)
                    .allowsHitTesting(isShowingLog)
            }

            if let display = machine?.display {
                VirtualMachineDisplayView(display: display)
                    .opacity(isShowingLog ? 0 : 1)
                    .disabled(isShowingLog)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: presentation.page)
        .task(id: record.id) {
            while !Task.isCancelled {
                presentation.update(console: console, display: machine?.display, isFailed: machine?.state.isFailed == true)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var isShowingLog: Bool {
        presentation.page == .log
    }

    private var console: VirtualMachineConsole? {
        engine.virtualMachines.console(for: record)
    }

    private var machine: (any VirtualMachine)? {
        engine.virtualMachines.machine(for: record)
    }
}

struct VirtualMachinePageToggle: View {
    let presentation: VirtualMachinePresentation

    var body: some View {
        Button {
            presentation.toggle()
        } label: {
            Image(systemName: isShowingLog ? "display" : "terminal")
                .frame(width: 18, height: 18)
                .overlay(alignment: .topTrailing) {
                    if presentation.hasUnseenAlarm {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .buttonStyle(.borderless)
        .help(isShowingLog ? "Show Screen" : "Show Log")
        .accessibilityLabel(isShowingLog ? "Show Screen" : "Show Log")
    }

    private var isShowingLog: Bool {
        presentation.page == .log
    }
}

private struct LogBehindScreenLayout: Layout {
    let logHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count > 1 else {
            return CGSize(width: proposal.width ?? 0, height: logHeight ?? proposal.height ?? 0)
        }
        return subviews[1].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

extension VirtualMachineState {
    var isFailed: Bool {
        guard case .failed = self else { return false }
        return true
    }
}

#endif
