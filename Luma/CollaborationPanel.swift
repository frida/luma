import AppKit
import Frida
import SwiftUI

struct CollaborationPanel: View {
    @ObservedObject var workspace: Workspace

    @State private var didCopyInvite = false

    @State private var focusChatField = false
    @State private var isPinnedToBottom = true
    private let chatBottomID = "CHAT_BOTTOM_ANCHOR"

    var body: some View {
        VStack(spacing: 12) {
            header
            Divider()
            roomSection

            if workspace.isCollaborationActive {
                Divider()
                participantsSection
                Divider()
                chatSection
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(12)
        .background(.ultraThickMaterial)
        .sheet(isPresented: $workspace.isAuthSheetPresented) {
            GitHubSignInSheet(workspace: workspace)
        }
        .onAppear {
            if case .joined = workspace.collaborationStatus {
                focusChatField = true
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.2.wave.2")
            Text("Collaboration")
                .font(.headline)
            Spacer()
            if let user = workspace.currentGitHubUser {
                Menu {
                    Button("View GitHub Profile") {
                        openGitHubProfile(for: user)
                    }
                    Button("Sign out", role: .destructive) {
                        workspace.signOut()
                    }
                } label: {
                    AsyncImage(url: URL(string: user.avatarURL + "&s=20")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle")
                    }
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
            }

            Button {
                workspace.isCollaborationPanelVisible = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private var roomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project collaboration")
                .font(.subheadline).bold()

            switch workspace.collaborationStatus {
            case .disconnected:
                if let stored = workspace.storedProjectRoomID {
                    Text("This project is already linked to a shared notebook (room \(truncatedRoomID(stored))).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        "Enable collaboration to rejoin that shared room. Any other copies of this project will connect to the same notebook."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                } else {
                    Text("Collaboration is currently off for this project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Enable collaboration to create a shared notebook and chat.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                if let user = workspace.currentGitHubUser {
                    Button("Enable collaboration as @\(user.id)") {
                        workspace.startCollaboration()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Enable collaboration") {
                        workspace.startCollaboration()
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .connecting:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Connecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .joined:
                if let roomID = workspace.collaborationRoomID {
                    HStack {
                        Text(workspace.isCollaborationHost ? "You are hosting this room." : "You joined this room.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    let inviteURL = "luma://join?room=\(roomID)"

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Room:")
                                .font(.caption2).bold()
                            Text(truncatedRoomID(roomID))
                                .font(.caption2)
                                .textSelection(.enabled)
                            Spacer()
                        }

                        HStack(spacing: 4) {
                            Text("Invite link:")
                                .font(.caption2).bold()
                            Text(inviteURL)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)

                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(inviteURL, forType: .string)
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                    didCopyInvite = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        didCopyInvite = false
                                    }
                                }
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy invite link")
                            .accessibilityLabel("Copy invite link")
                        }

                        Text("Share this link so others can open a new project and join this notebook.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .overlay(alignment: .top) {
                        if didCopyInvite {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Copied!")
                                    .font(.callout.weight(.medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThickMaterial)
                            .clipShape(Capsule())
                            .shadow(radius: 3, y: 2)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .accessibilityHidden(true)
                            .padding(.top, -6)
                        }
                    }
                } else {
                    Text("Collaboration is active for this project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Disable collaboration") {
                    workspace.stopCollaboration()
                }
                .buttonStyle(.bordered)

            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)

                Button("Retry") {
                    workspace.startCollaboration()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func truncatedRoomID(_ id: String) -> String {
        if id.count <= 8 { return id }
        let prefix = id.prefix(4)
        let suffix = id.suffix(4)
        return "\(prefix)…\(suffix)"
    }

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Participants")
                    .font(.subheadline).bold()
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.collaborationParticipants) { user in
                        avatarView(for: user)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 28)
        }
    }

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chat")
                .font(.subheadline).bold()

            GeometryReader { outer in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(workspace.collaborationChatMessages) { msg in
                                HStack(alignment: .top, spacing: 4) {
                                    if msg.isLocalUser {
                                        Spacer()
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            avatarView(for: msg.user)
                                            Text("@\(msg.user.id)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text(msg.timestamp, style: .time)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary.opacity(0.7))
                                        }

                                        Text(msg.text)
                                            .font(.caption)
                                    }
                                    .padding(6)
                                    .background(
                                        msg.isLocalUser
                                            ? Color.accentColor.opacity(0.2)
                                            : Color.secondary.opacity(0.1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                    if !msg.isLocalUser {
                                        Spacer()
                                    }
                                }
                            }

                            Color.clear
                                .frame(height: 0)
                                .id(chatBottomID)
                        }
                        .frame(minHeight: outer.size.height, alignment: .bottomLeading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .coordinateSpace(name: "chatScroll")
                    .simultaneousGesture(
                        DragGesture().onChanged { _ in
                            isPinnedToBottom = false
                        }
                    )
                    .onChange(of: workspace.collaborationChatMessages.count) { _, _ in
                        if isPinnedToBottom {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(chatBottomID, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(chatBottomID, anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 80)

            ChatInputRow(workspace: workspace, isFocused: $focusChatField)
                .onChange(of: focusChatField) { _, newVal in
                    if newVal {
                        isPinnedToBottom = true
                    }
                }
        }
    }

    private func avatarView(for user: Workspace.UserInfo) -> some View {
        Group {
            if let url = URL(string: user.avatarURL + "&s=40") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .scaleEffect(0.5)

                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()

                    case .failure:
                        Image(systemName: "person.fill")
                            .resizable()
                            .scaledToFit()
                            .padding(4)

                    @unknown default:
                        Image(systemName: "person.fill")
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    }
                }
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
        )
        .help(user.displayName)
        .onTapGesture {
            openGitHubProfile(for: user)
        }
    }

    private func openGitHubProfile(for user: Workspace.UserInfo) {
        let urlString = "https://github.com/\(user.id)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct ChatInputRow: View {
    @ObservedObject var workspace: Workspace
    @Binding var isFocused: Bool
    @State private var draft: String = ""
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        HStack {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($textFieldFocused)
                .onSubmit {
                    send()
                }

            Button {
                send()
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(!canSend)
        }
        .font(.caption)
        .onAppear {
            if isFocused {
                DispatchQueue.main.async {
                    textFieldFocused = true
                }
            }
        }
        .onChange(of: isFocused) { _, newValue in
            if newValue {
                DispatchQueue.main.async {
                    textFieldFocused = true
                }
            }
        }
        .onChange(of: textFieldFocused) { _, newValue in
            if isFocused != newValue {
                isFocused = newValue
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && workspace.isCollaborationActive
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard workspace.isCollaborationActive else { return }

        workspace.sendChatMessage(text)
        draft = ""
    }
}
