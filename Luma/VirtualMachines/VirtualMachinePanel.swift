import Frida
import LumaCore
import SwiftUI

struct VirtualMachinePanel: View {
    let engine: Engine

    @State private var miniaturized: Set<UUID> = []
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if !records.isEmpty {
                machineList
            } else {
                ContentUnavailableView(
                    "No Machines",
                    systemImage: "desktopcomputer",
                    description: Text("Boot one from the target picker to see it here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var machineList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(records) { record in
                    VirtualMachineControls(
                        engine: engine,
                        record: record,
                        isMiniature: miniature(record),
                        failure: $failure
                    )

                    if record.id != records.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func miniature(_ record: VirtualMachineRecord) -> Binding<Bool> {
        Binding(
            get: { miniaturized.contains(record.id) },
            set: { wanted in
                if wanted {
                    miniaturized.insert(record.id)
                } else {
                    miniaturized.remove(record.id)
                }
            }
        )
    }

    private var header: some View {
        HStack {
            Text("Machines")
                .font(.headline)

            Spacer()

            Button {
                engine.setSidePanel(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private var records: [VirtualMachineRecord] {
        engine.virtualMachines.records
    }
}

struct VirtualMachineControls: View {
    let engine: Engine
    let record: VirtualMachineRecord

    @Binding var isMiniature: Bool
    @Binding var failure: String?

    @State private var isConfirmingForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary

            if !isMiniature, let display = machine?.display {
                VirtualMachineDisplayView(display: display)
            }
        }
        .confirmationDialog("Forget Machine?", isPresented: $isConfirmingForget, titleVisibility: .visible) {
            Button("Forget Machine", role: .destructive) {
                Task { await engine.virtualMachines.forget(record) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will stop \"\(record.name)\" and delete its snapshot. Its disk image is left alone.")
        }
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                isMiniature.toggle()
            } label: {
                Image(systemName: isMiniature ? "chevron.forward" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(isMiniature ? "Show the screen at full size" : "Collapse the screen into a miniature")

            if let icon = engine.virtualMachines.template(for: record)?.icon {
                icon.swiftUIImage
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.subheadline.weight(.medium))

                if let template = engine.virtualMachines.template(for: record), template.name != record.name {
                    Text(template.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if isMiniature, let display = machine?.display {
                VirtualMachineDisplayView(display: display)
                    .frame(height: Self.miniatureHeight)
            }

            if let passingState {
                Text(passingState)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            primaryAction

            Menu {
                lessTravelledActions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let machine {
            action("Stop", systemImage: "stop.fill") {
                Task { await engine.virtualMachines.stop(record) }
            }
            .disabled(machine.state == .starting)
        } else {
            action(record.hasReadySnapshot ? "Resume where it was marked ready" : "Boot", systemImage: "play.fill") {
                perform { _ = try await engine.virtualMachines.boot(record) }
            }
        }
    }

    @ViewBuilder
    private var lessTravelledActions: some View {
        if let machine {
            Button("Mark Ready") {
                perform { try await engine.virtualMachines.markReady(machine) }
            }
            .disabled(!machine.capabilities.contains(.snapshot))

            Button("Back to Ready") {
                perform { try await machine.restoreReadySnapshot() }
            }
            .disabled(!machine.capabilities.contains(.snapshot) || !record.hasReadySnapshot)
        } else if record.hasReadySnapshot {
            Button("Boot Fresh, Leaving the Snapshot Behind") {
                perform { _ = try await engine.virtualMachines.boot(record, resumingFromReadySnapshot: false) }
            }
        }

        if record.hasReadySnapshot {
            Button("Forget the Ready Snapshot") {
                perform { try await engine.virtualMachines.discardReadySnapshot(record) }
            }
        }

        Divider()

        Button("Forget Machine…", role: .destructive) {
            isConfirmingForget = true
        }
    }

    private func action(_ name: String, systemImage: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(name)
        .accessibilityLabel(name)
    }

    private static let miniatureHeight: CGFloat = 40

    /// Running and stopped are what the button beside this already says; the
    /// states worth a word are the ones on the way to somewhere.
    private var passingState: String? {
        switch machine?.state {
        case .running, .stopped, nil:
            return nil
        case .some(let state):
            return state.summary
        }
    }

    private var machine: (any VirtualMachine)? {
        engine.virtualMachines.machine(for: record)
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        failure = nil
        Task {
            do {
                try await work()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

extension VirtualMachineState {
    var summary: String {
        switch self {
        case .starting: return "Starting…"
        case .installing(let fraction): return "Installing… \(Int(fraction * 100))%"
        case .running: return "Running"
        case .capturingSnapshot: return "Taking a snapshot…"
        case .restoringSnapshot: return "Going back to the snapshot…"
        case .stopped: return "Stopped"
        case .failed(let reason): return reason
        }
    }
}
