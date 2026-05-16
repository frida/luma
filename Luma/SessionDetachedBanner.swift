import Frida
import LumaCore
import SwiftUI

struct SessionContent<Content: View>: View {
    let sessionID: UUID?
    let engine: Engine
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            switch bannerState {
            case .armed(let session):
                SessionArmedBanner(session: session, engine: engine)
            case .detached(let session):
                SessionDetachedBanner(session: session, engine: engine)
            case .idle(let session):
                SessionIdleBanner(session: session, engine: engine)
            case .none:
                EmptyView()
            }
            content()
        }
    }

    private enum BannerState {
        case armed(LumaCore.ProcessSession)
        case detached(LumaCore.ProcessSession)
        case idle(LumaCore.ProcessSession)
        case none
    }

    private var bannerState: BannerState {
        guard let sessionID,
              let session = engine.sessions.first(where: { $0.id == sessionID })
        else { return .none }

        let isAttached = engine.node(forSessionID: session.id) != nil
        if !isAttached, case .armed = session.armingState {
            return .armed(session)
        }
        let hasError = session.lastError != nil
        if isAttached && !hasError {
            return .none
        }
        if !isAttached,
           !hasError,
           engine.collaboration.isCollaborative,
           session.host != nil,
           session.phase == .attached || session.phase == .attaching
        {
            return .none
        }
        if session.lastAttachedAt != nil {
            return .detached(session)
        }
        if case .attach = session.kind {
            return .detached(session)
        }
        return .idle(session)
    }
}

struct SessionIdleBanner: View {
    let session: LumaCore.ProcessSession
    let engine: Engine

    @State private var isShowingArmPrompt = false
    @State private var armPatternDraft = ""

    var body: some View {
        LumaBanner(style: .warning) {
            HStack {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "bolt.slash")
                        .font(.headline)
                    Text(session.processName)
                        .font(.headline)
                    Divider()
                        .frame(height: 16)
                    Text("Idle — not waiting for a launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    presentArmPrompt()
                } label: {
                    Label("Arm…", systemImage: "scope")
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
        .alert("Arm for Next Launch", isPresented: $isShowingArmPrompt) {
            TextField("Identifier regex", text: $armPatternDraft)
                .disableAutocorrection(true)
            Button("Arm") { commitArm() }
                .disabled(armPatternDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Match the next spawn whose identifier matches this regex on \(session.deviceName).")
        }
    }

    private func presentArmPrompt() {
        armPatternDraft = engine.defaultArmPattern(for: session)
        isShowingArmPrompt = true
    }

    private func commitArm() {
        let pattern = armPatternDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        let sessionID = session.id
        Task { @MainActor in
            await engine.armSession(id: sessionID, matchPattern: pattern)
        }
    }
}

struct SessionArmedBanner: View {
    let session: LumaCore.ProcessSession
    let engine: Engine

    var body: some View {
        LumaBanner(style: bannerStyle) {
            HStack {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "scope")
                        .font(.headline)

                    Text(session.processName)
                        .font(.headline)

                    Divider()
                        .frame(height: 16)

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("session.armedStatus")
                }

                Spacer()

                if !isActive {
                    Button {
                        resume()
                    } label: {
                        Label("Resume", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
                }

                Button {
                    disarm()
                } label: {
                    Label("Disarm", systemImage: "scope")
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
    }

    private var isActive: Bool {
        engine.isGatingActive(forDeviceID: session.deviceID)
    }

    private var hasError: Bool {
        session.lastError != nil
    }

    private var bannerStyle: LumaBannerStyle {
        if hasError { return .error }
        return isActive ? .info : .warning
    }

    private var statusText: String {
        if let lastError = session.lastError {
            return "Armed but inactive — \(lastError)"
        }
        if !isActive {
            return "Armed but inactive — spawn gating is paused. Resume to enable it."
        }
        let pattern = session.armingState.matchPattern ?? ""
        return pattern.isEmpty
            ? "Waiting for the next matching launch."
            : "Waiting for the next launch matching \(pattern)."
    }

    private func resume() {
        let sessionID = session.id
        Task { @MainActor in
            await engine.resumeGating(forSessionID: sessionID)
        }
    }

    private func disarm() {
        let sessionID = session.id
        Task { @MainActor in
            await engine.disarmSession(id: sessionID)
        }
    }
}

struct SessionDetachedBanner: View {
    let session: LumaCore.ProcessSession
    let engine: Engine

    @Environment(TargetPicker.self) private var picker

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

                            Text(session.kind.inProgressLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let errorText = errorText {
                        let errorPrefix = "Last \(session.kind.verbDisplayName) attempt failed: "
                        Text(errorPrefix + errorText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("session.errorText")
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
            return "Not currently attached."
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
            let result = await engine.reestablishSession(id: session.id)
            if case .needsUserInput(let reason, let session) = result {
                picker.context = .reestablish(session: session, reason: reason)
            }
        }
    }
}

