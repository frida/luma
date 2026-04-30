import LumaCore
import SwiftUI

struct SessionCollaborationHeader: View {
    let sessionID: UUID
    @ObservedObject var workspace: Workspace

    var body: some View {
        if host != nil || driver != nil {
            HStack(spacing: 10) {
                if let host {
                    HStack(spacing: 6) {
                        UserAvatarView(user: host, size: 18)
                        Text("Hosted by @\(host.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if host != nil, driver != nil {
                    Text("·").foregroundStyle(.secondary)
                }

                if let driver {
                    HStack(spacing: 6) {
                        UserAvatarView(user: driver, size: 18)
                        Text("Driving: @\(driver.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if host != nil, workspace.engine.collaboration.isOwner {
                    Button("Run on My Device…") {
                        rehost()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if !localUserIsDriver, workspace.engine.collaboration.isOwner {
                    Button("Take the wheel") {
                        workspace.engine.collaboration.enqueueClaimDriver(sessionID: sessionID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
        }
    }

    private var host: LumaCore.CollaborationSession.UserInfo? {
        guard let session = workspace.engine.sessions.first(where: { $0.id == sessionID }),
              let host = session.host,
              host.id != workspace.engine.collaboration.localUser?.id
        else { return nil }
        return host
    }

    private var driver: LumaCore.CollaborationSession.UserInfo? {
        guard !localUserIsDriver else { return nil }
        return workspace.engine.driver(forSessionID: sessionID)
    }

    private var localUserIsDriver: Bool {
        workspace.engine.localUserIsDriver(ofSessionID: sessionID)
    }

    private func rehost() {
        Task { @MainActor in
            let result = await workspace.engine.reHost(sessionID: sessionID)
            if case .needsUserInput(let reason, let session) = result {
                workspace.targetPickerContext = .reestablish(session: session, reason: reason)
            }
        }
    }
}
