import AppKit
import Frida
import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct CollaborationPanel: View {
    @ObservedObject var workspace: Workspace

    @State private var didCopyInvite = false

    @State private var focusChatField = false
    @State private var isPinnedToBottom = true
    private let chatBottomID = "CHAT_BOTTOM_ANCHOR"

    private var collaboration: CollaborationSession {
        workspace.engine.collaboration
    }

    private var isActive: Bool {
        if case .joined = collaboration.status { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            Divider()
            labSection

            if isActive {
                Divider()
                participantsSection
                Divider()
                chatSection
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(12)
        .background(.ultraThickMaterial)
        .sheet(
            isPresented: Binding(
                get: { workspace.engine.gitHubAuth.isPresentingSignIn },
                set: { if !$0 { workspace.engine.gitHubAuth.dismissSignIn() } }
            )
        ) {
            GitHubSignInSheet(auth: workspace.engine.gitHubAuth)
        }
        .onAppear {
            if case .joined = collaboration.status {
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
            if let user = workspace.engine.gitHubAuth.currentUser {
                Menu {
                    Button("View GitHub Profile") {
                        openGitHubProfile(for: user)
                    }
                    Button("Sign out", role: .destructive) {
                        Task { @MainActor in
                            await workspace.engine.gitHubAuth.signOut()
                            await workspace.engine.collaboration.stop()
                        }
                    }
                } label: {
                    AsyncImage(url: avatarSizeURL(user, size: 20)) { image in
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

    private var labSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch collaboration.status {
            case .disconnected:
                let storedLabID = (try? workspace.store.fetchCollaborationState())?.labID
                if let stored = storedLabID {
                    Text("This project is already linked to a shared notebook (lab \(truncatedLabID(stored))).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        "Enable collaboration to rejoin that shared lab. Any other copies of this project will connect to the same notebook."
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

                if let user = workspace.engine.gitHubAuth.currentUser {
                    Button("Enable collaboration as @\(user.id)") {
                        workspace.engine.startCollaboration()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Enable collaboration") {
                        workspace.engine.startCollaboration()
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
                if let labID = collaboration.labID {
                    HStack(alignment: .top, spacing: 10) {
                        LabPictureView(collaboration: collaboration)
                        LabTitleView(collaboration: collaboration)
                    }

                    HStack {
                        Text(collaboration.isHost ? "You are hosting this lab." : "You joined this lab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    let inviteURL = "\(BackendConfig.inviteLinkBase)\(labID)"

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Invite link:")
                                .font(.caption2).bold()
                            Text(inviteURL)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)

                            Button {
                                Platform.copyToClipboard(inviteURL)
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

                Button("Disconnect from lab") {
                    Task { @MainActor in await workspace.engine.collaboration.stop() }
                }
                .buttonStyle(.bordered)

            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)

                Button("Retry") {
                    workspace.engine.startCollaboration()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func truncatedLabID(_ id: String) -> String {
        if id.count <= 8 { return id }
        let prefix = id.prefix(4)
        let suffix = id.suffix(4)
        return "\(prefix)…\(suffix)"
    }

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Members")
                    .font(.subheadline).bold()
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sortedMembers) { member in
                        memberAvatarView(for: member)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 32)
        }
    }

    private var sortedMembers: [CollaborationSession.Member] {
        collaboration.members.sorted { a, b in
            if (a.role == .owner) != (b.role == .owner) { return a.role == .owner }
            if (a.presence == .online) != (b.presence == .online) {
                return a.presence == .online
            }
            return a.joinedAt < b.joinedAt
        }
    }

    private func memberAvatarView(for member: CollaborationSession.Member) -> some View {
        let online = member.presence == .online
        let isOwner = member.role == .owner
        return avatarView(for: member.user)
            .opacity(online ? 1.0 : 0.55)
            .overlay(alignment: .topTrailing) {
                if isOwner {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(red: 0.94, green: 0.39, blue: 0.34))
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(online ? Color(red: 0.36, green: 0.78, blue: 0.41) : Color.secondary.opacity(0.6))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(.windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            .help(memberTooltip(member))
    }

    private func memberTooltip(_ member: CollaborationSession.Member) -> String {
        let role = member.role == .owner ? "owner" : "member"
        let presence = member.presence == .online ? "online" : "offline"
        return "\(member.user.name) · \(role) · \(presence)"
    }

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chat")
                .font(.subheadline).bold()

            GeometryReader { outer in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(collaboration.chatMessages) { msg in
                                HStack(alignment: .top, spacing: 4) {
                                    if msg.isLocal {
                                        Spacer()
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            avatarView(for: msg.sender)
                                            Text("@\(msg.sender.id)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            RelativeTimeText(
                                                date: msg.timestamp,
                                                color: .secondary.opacity(0.7)
                                            )
                                            .help(msg.timestamp.formatted())
                                        }

                                        Text(msg.text)
                                            .font(.caption)
                                    }
                                    .padding(6)
                                    .background(
                                        msg.isLocal
                                            ? Color.accentColor.opacity(0.2)
                                            : Color.secondary.opacity(0.1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                    if !msg.isLocal {
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
                    .onChange(of: collaboration.chatMessages.count) { _, _ in
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

    private func avatarSizeURL(_ user: CollaborationSession.UserInfo, size: Int) -> URL? {
        guard let base = user.avatarURL else { return nil }
        return URL(string: "\(base.absoluteString)&s=\(size)")
    }

    private func avatarView(for user: CollaborationSession.UserInfo) -> some View {
        Group {
            if let url = avatarSizeURL(user, size: 40) {
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
        .help(user.name)
        .onTapGesture {
            openGitHubProfile(for: user)
        }
    }

    private func openGitHubProfile(for user: CollaborationSession.UserInfo) {
        let urlString = "https://github.com/\(user.id)"
        guard let url = URL(string: urlString) else { return }
        Platform.openURL(url)
    }
}

private struct ChatInputRow: View {
    @ObservedObject var workspace: Workspace
    @Binding var isFocused: Bool
    @State private var draft: String = ""
    @FocusState private var textFieldFocused: Bool

    private var collaboration: CollaborationSession {
        workspace.engine.collaboration
    }

    private var isActive: Bool {
        if case .joined = collaboration.status { return true }
        return false
    }

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
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isActive
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isActive else { return }

        collaboration.sendChat(text)
        draft = ""
    }
}

private struct LabPictureView: View {
    var collaboration: CollaborationSession

    private static let supportedTypes: [(contentType: String, uti: String)] = [
        ("image/png", "public.png"),
        ("image/jpeg", "public.jpeg"),
        ("image/webp", "org.webmproject.webp"),
        ("image/gif", "com.compuserve.gif"),
    ]

    var body: some View {
        Group {
            if collaboration.isOwner {
                Menu {
                    Button("Upload Image\u{2026}", action: pickImage)
                    if collaboration.labPictureData != nil {
                        Button("Reset to Default", role: .destructive) {
                            Task { @MainActor in
                                await collaboration.removeLabPicture()
                            }
                        }
                    }
                } label: {
                    pictureView
                }
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .help("Change lab picture")
            } else {
                pictureView
            }
        }
    }

    @ViewBuilder
    private var pictureView: some View {
        if let data = collaboration.labPictureData,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let owner = collaboration.members.first(where: { $0.role == .owner }),
                  let url = owner.user.avatarURL.flatMap({ URL(string: "\($0.absoluteString)&s=96") }) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.1)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedTypes.compactMap {
            UTType($0.uti)
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        let ext = url.pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "png": contentType = "image/png"
        case "jpg", "jpeg": contentType = "image/jpeg"
        case "webp": contentType = "image/webp"
        case "gif": contentType = "image/gif"
        default: contentType = "image/png"
        }

        Task { @MainActor in
            await collaboration.setLabPicture(data, contentType: contentType)
        }
    }
}

private struct LabTitleView: View {
    var collaboration: CollaborationSession

    @State private var isEditing = false
    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                TextField("Title", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .focused($fieldFocused)
                    .onSubmit(commit)

                Button("Save", action: commit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel") { isEditing = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text(collaboration.labTitle ?? "Untitled")
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                if collaboration.isOwner {
                    Button {
                        draft = collaboration.labTitle ?? ""
                        isEditing = true
                        DispatchQueue.main.async { fieldFocused = true }
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Rename lab")
                }
            }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !trimmed.isEmpty, trimmed != collaboration.labTitle else { return }
        Task { @MainActor in
            await collaboration.setLabTitle(trimmed)
        }
    }
}
