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
            stack(topPadding: 56, bottomPadding: 100)
                .containerBackground(for: .window) {
                    WelcomeBackdrop()
                }
        #else
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        stack(topPadding: 0, bottomPadding: 0)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: proxy.size.height)
                }
            }
            .background {
                WelcomeBackdrop().ignoresSafeArea()
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
        VStack(spacing: 14) {
            LumaWordmark()
            nowSecurePartnership
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    private var nowSecurePartnership: some View {
        Link(destination: URL(string: "https://www.nowsecure.com")!) {
            HStack(spacing: 4) {
                Text("Sponsored by")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Image("NowSecureLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 20)
                    .accessibilityLabel("NowSecure")
            }
            .opacity(0.9)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .help("nowsecure.com")
    }

    private var quickActions: some View {
        VStack(spacing: 10) {
            ActionRow(
                title: "New Project",
                subtitle: "Start with an empty workspace",
                systemImage: "doc.badge.plus",
                action: onCreateBlank
            )
            .accessibilityIdentifier("welcome.newProject")
            ActionRow(
                title: "Open Project\u{2026}",
                subtitle: "Choose a .luma project from disk",
                systemImage: "folder",
                action: onOpenExisting
            )
            .accessibilityIdentifier("welcome.openProject")
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
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
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
                        Label {
                            Text(user.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } icon: {
                            Image(systemName: "person.circle")
                        }
                        .labelStyle(.titleAndIcon)
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .menuStyle(.borderlessButton)
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

private struct LumaWordmark: View {
    @Environment(\.colorScheme) private var colorScheme

    private static let cream = Color(red: 0.929, green: 0.902, blue: 0.882)
    private static let coral = Color(red: 0.937, green: 0.392, blue: 0.337)

    var body: some View {
        VStack(spacing: 6) {
            Text("Luma")
                .font(.system(size: 64, weight: .semibold))
                .tracking(-2)
                .foregroundStyle(colorScheme == .dark ? Self.cream : Self.coral)

            LinearGradient(
                colors: [
                    Self.coral.opacity(0),
                    Self.coral.opacity(0.55),
                    Self.coral.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 200, height: 1.5)
        }
    }
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
        Image(platformImageData: data)
    }

    private var secondaryLabel: String {
        let people = lab.memberCount == 1 ? "1 member" : "\(lab.memberCount) members"
        if lab.onlineCount > 0 {
            return "\(people) · \(lab.onlineCount) online"
        }
        return people
    }
}
