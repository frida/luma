import Frida
import LumaCore
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct CollaborationPanel: View {
    @ObservedObject var workspace: Workspace

    @State private var didCopyInvite = false

    @State private var focusChatField = false
    @State private var isPinnedToBottom = true
    private let chatBottomID = "CHAT_BOTTOM_ANCHOR"

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompactWidth: Bool { false }
    #endif

    private var collaboration: CollaborationSession {
        workspace.engine.collaboration
    }

    private var isActive: Bool {
        if case .joined = collaboration.status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isCompactWidth {
                header
                Divider()
            }
            labSection

            if isActive {
                Divider()
                participantsSection
                Divider()
                chatSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        labSectionContent
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labSectionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch collaboration.status {
            case .disconnected:
                let storedLabID = (try? workspace.store.fetchCollaborationState())?.labID
                let hasExistingLab = storedLabID != nil
                if let stored = storedLabID {
                    Text("You're currently offline from the shared lab (lab \(truncatedLabID(stored))).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Reconnect to rejoin and resume syncing.")
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

                let actionLabel: String = {
                    if hasExistingLab {
                        return "Reconnect"
                    }
                    if let user = workspace.engine.gitHubAuth.currentUser {
                        return "Enable collaboration as @\(user.id)"
                    }
                    return "Enable collaboration"
                }()
                Button(actionLabel) {
                    workspace.engine.startCollaboration()
                }
                .buttonStyle(.borderedProminent)

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
                    HStack(alignment: .center, spacing: 10) {
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

                        Text("Share this link to invite others to this notebook.")
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
                    .overlay(Circle().stroke(Color.platformWindowBackground, lineWidth: 1.5))
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

    private static let pictureSize: CGFloat = 48

    var body: some View {
        Group {
            #if canImport(AppKit)
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
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Change lab picture")
            } else {
                pictureView
            }
            #else
            pictureView
            #endif
        }
    }

    @ViewBuilder
    private var pictureView: some View {
        pictureContent
            .frame(width: Self.pictureSize, height: Self.pictureSize)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var pictureContent: some View {
        if let data = collaboration.labPictureData,
           let image = Self.loadImage(from: data) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let owner = collaboration.members.first(where: { $0.role == .owner }),
                  let url = owner.user.avatarURL.flatMap({
                      URL(string: "\($0.absoluteString)&s=\(Int(Self.pictureSize * 2))")
                  }) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.1)
            }
        } else {
            Color.secondary.opacity(0.15)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private static func loadImage(from data: Data) -> Image? {
        #if canImport(AppKit)
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        return nil
        #elseif canImport(UIKit)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
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

        let (bytes, contentType) = normalizedPicture(from: data, originalExtension: url.pathExtension)

        Task { @MainActor in
            await collaboration.setLabPicture(bytes, contentType: contentType)
        }
    }

    /// Downscale the user-supplied image to at most 512×512 and re-
    /// encode as JPEG. Keeps the wire payload well under the server's
    /// 512 KiB cap and prevents a multi-megapixel file from tanking
    /// the UI when we render it into a 48-pt slot. Images already
    /// smaller than the cap pass through unchanged.
    private func normalizedPicture(
        from data: Data,
        originalExtension ext: String,
    ) -> (Data, String) {
        let maxDimension: CGFloat = 512
        let passthrough: (Data, String) = {
            switch ext.lowercased() {
            case "png": return (data, "image/png")
            case "jpg", "jpeg": return (data, "image/jpeg")
            case "webp": return (data, "image/webp")
            case "gif": return (data, "image/gif")
            default: return (data, "image/png")
            }
        }()

        guard let image = NSImage(data: data) else { return passthrough }
        let size = image.size
        let longest = max(size.width, size.height)
        if longest <= maxDimension && data.count <= 512 * 1024 {
            return passthrough
        }

        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: .zero,
            operation: .copy,
            fraction: 1.0,
        )
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.85]
              )
        else { return passthrough }
        return (jpeg, "image/jpeg")
    }
    #endif
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
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
