import Frida
import LumaCore
import SwiftUI

struct SessionDetachedBanner: View {
    let session: LumaCore.ProcessSession
    @ObservedObject var workspace: Workspace

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
        session.lastError
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
            let result = await workspace.engine.reestablishSession(id: session.id)
            if case .needsUserInput(let reason, let session) = result {
                workspace.targetPickerContext = .reestablish(session: session, reason: reason)
            }
        }
    }
}
