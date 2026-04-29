import LumaCore
import SwiftUI

struct WelcomeView: View {
    let welcome: WelcomeModel
    let onCreateBlank: () -> Void
    let onOpenExisting: () -> Void
    let onCreateFromLab: (WelcomeModel.LabSummary) -> Void

    var body: some View {
        @Bindable var auth = welcome.gitHubAuth
        contentBody
            .background(Color.platformWindowBackground)
            .sheet(isPresented: $auth.isPresentingSignIn) {
                GitHubSignInSheet(auth: welcome.gitHubAuth)
            }
            .onChange(of: welcome.gitHubAuth.token) { _, newToken in
                if newToken != nil {
                    Task { await welcome.refreshLabs() }
                }
            }
    }

    @ViewBuilder
    private var contentBody: some View {
        #if os(macOS)
            stack(topPadding: 4, bottomPadding: 56)
                .containerBackground(Color.platformWindowBackground, for: .window)
        #else
            ScrollView {
                stack(topPadding: 32, bottomPadding: 32)
            }
        #endif
    }

    private func stack(topPadding: CGFloat, bottomPadding: CGFloat) -> some View {
        VStack(spacing: 28) {
            heroBanner
            quickActions
            continueFromLabSection
        }
        .padding(.horizontal, 20)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: 430)
        .frame(maxWidth: .infinity)
    }

    private var heroBanner: some View {
        VStack(spacing: 16) {
            AppIconView()
                .frame(width: 104, height: 104)

            Text("The official Frida GUI.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
    }

    private var quickActions: some View {
        VStack(spacing: 10) {
            ActionRow(
                title: "New Project",
                subtitle: "Start with an empty workspace.",
                systemImage: "doc.badge.plus",
                action: onCreateBlank
            )
            ActionRow(
                title: "Open Project\u{2026}",
                subtitle: "Pick a .luma file from disk or iCloud Drive.",
                systemImage: "folder",
                action: onOpenExisting
            )
        }
    }

    @ViewBuilder
    private var continueFromLabSection: some View {
        if welcome.gitHubAuth.token != nil {
            labsList
        } else {
            switch welcome.gitHubAuth.state {
            case .requestingCode, .waitingForApproval, .authenticated:
                ProgressView("Waiting for GitHub\u{2026}")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            case .signedOut, .failed:
                signedOutPrompt
            }
        }
    }

    private var signedOutPrompt: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.tint)
                Text("Continue from a lab")
                    .font(.headline)
            }

            Text(
                "Sign in with GitHub to find your labs, "
                + "including any started on another machine."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                welcome.signIn()
            } label: {
                Label("Sign in with GitHub", systemImage: "person.crop.circle")
                    .frame(maxWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if case .failed(let reason) = welcome.gitHubAuth.state {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var labsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Continue from a lab")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await welcome.refreshLabs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                Menu {
                    Button("Sign Out", role: .destructive) {
                        Task { await welcome.signOut() }
                    }
                } label: {
                    if let user = welcome.gitHubAuth.currentUser {
                        Label(user.name, systemImage: "person.circle")
                            .labelStyle(.titleAndIcon)
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            labsContent
        }
    }

    @ViewBuilder
    private var labsContent: some View {
        switch welcome.labsState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)

        case .failed(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try Again") {
                    Task { await welcome.refreshLabs() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

        case .idle:
            emptyLabsHint

        case .loaded:
            if welcome.labs.isEmpty {
                emptyLabsHint
            } else {
                labRows
            }
        }
    }

    @ViewBuilder
    private var labRows: some View {
        let stack = VStack(spacing: 6) {
            ForEach(welcome.labs) { lab in
                LabRow(lab: lab) { onCreateFromLab(lab) }
            }
        }
        #if os(macOS)
            if welcome.labs.count > 3 {
                ScrollView { stack }
                    .frame(height: 180)
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                stack
            }
        #else
            stack
        #endif
    }

    private var emptyLabsHint: some View {
        Text("No collaborative labs yet. Start a new project, then invite people from the collaboration panel.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
    }
}

private struct AppIconView: View {
    var body: some View {
        #if canImport(AppKit)
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
        #elseif canImport(UIKit)
        if let icon = UIImage(named: "AppIcon") ?? primaryIcon() {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        Image(systemName: "scope")
            .resizable()
            .scaledToFit()
            .padding(16)
            .foregroundStyle(.tint)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    #if canImport(UIKit)
    private func primaryIcon() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last
        else { return nil }
        return UIImage(named: last)
    }
    #endif
}

private struct ActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct LabRow: View {
    let lab: WelcomeModel.LabSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(lab.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(secondaryLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if lab.role == "owner" {
                    Text("Owner")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var avatar: some View {
        if let platformImage = Self.makeImage(from: lab.pictureData) {
            platformImage
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.2.fill")
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.2), in: Circle())
                .foregroundStyle(.secondary)
        }
    }

    private static func makeImage(from data: Data) -> Image? {
        #if canImport(AppKit)
        if let nsImage = NSImage(data: data) {
            return Image(nsImage: nsImage)
        }
        #elseif canImport(UIKit)
        if let uiImage = UIImage(data: data) {
            return Image(uiImage: uiImage)
        }
        #endif
        return nil
    }

    private var secondaryLabel: String {
        let people = lab.memberCount == 1 ? "1 member" : "\(lab.memberCount) members"
        if lab.onlineCount > 0 {
            return "\(people) · \(lab.onlineCount) online"
        }
        return people
    }
}
