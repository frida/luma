import Frida
import SwiftUI

struct SessionDetachedBanner: View {
    @Bindable var session: ProcessSession
    @ObservedObject var workspace: Workspace

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        LumaBanner(style: bannerStyle) {
            HStack {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "bolt.slash")
                        .font(.headline)

                    Text(session.processName)
                        .font(.headline)

                    if session.phase == .attaching || errorText != nil || detachReasonText != nil {
                        Divider()
                            .frame(height: 16)
                    }

                    if session.phase == .attaching {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)

                            Text("\(session.kind.reestablishLabel)ing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let errorText = errorText {
                        let errorPrefix = "Last \(session.kind.verbDisplayName) attempt failed: "
                        Text(errorPrefix + errorText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let reasonText = detachReasonText {
                        Text(reasonText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    reestablish()
                } label: {
                    Label("\(session.kind.reestablishLabel)…", systemImage: "arrow.clockwise")
                }
                .disabled(session.phase == .attaching)
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
    }

    private var bannerStyle: LumaBannerStyle {
        switch session.detachReason {
        case .applicationRequested:
            return .warning
        default:
            return .error
        }
    }

    private var errorText: String? {
        guard let error = session.lastError else { return nil }
        switch error {
        case .serverNotRunning(let message):
            return "Server is not running: \(message)"
        case .executableNotFound(let message):
            return "Executable not found: \(message)"
        case .executableNotSupported(let message):
            return "Executable not supported: \(message)"
        case .processNotFound(let message):
            return "Process not found: \(message)"
        case .processNotResponding(let message):
            return "Process is not responding: \(message)"
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        case .invalidOperation(let message):
            return "Invalid operation: \(message)"
        case .permissionDenied(let message):
            return "Permission denied: \(message)"
        case .addressInUse(let message):
            return "Address already in use: \(message)"
        case .timedOut(let message):
            return "Operation timed out: \(message)"
        case .notSupported(let message):
            return "Operation not supported: \(message)"
        case .protocolViolation(let message):
            return "Protocol violation: \(message)"
        case .transport(let message):
            return "Transport error: \(message)"
        case .rpcError(let message, let stackTrace):
            if let stackTrace = stackTrace {
                return "RPC error: \(message)\nStack trace:\n\(stackTrace)"
            } else {
                return "RPC error: \(message)"
            }
        }
    }

    private var detachReasonText: String? {
        switch session.detachReason {
        case .applicationRequested:
            return nil
        case .processReplaced:
            return "Detached because the process was replaced."
        case .processTerminated:
            return "Detached because the process terminated."
        case .connectionTerminated:
            return "Detached because the connection was terminated."
        case .deviceLost:
            return "Detached because the device connection was lost."
        }
    }

    private func reestablish() {
        Task { @MainActor in
            await workspace.reestablishSession(for: session, modelContext: modelContext)
        }
    }
}
