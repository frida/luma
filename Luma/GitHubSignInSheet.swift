import LumaCore
import SwiftUI

struct GitHubSignInSheet: View {
    let auth: GitHubAuth
    @State private var didCopyCode = false

    var body: some View {
        VStack(spacing: 16) {
            Image("GitHubMark")
                .resizable()
                .frame(width: 40, height: 40)

            Text("Sign in with GitHub")
                .font(.headline)

            switch auth.state {
            case .signedOut:
                Button("Sign in with GitHub") {
                    auth.beginSignIn()
                }
                .buttonStyle(.borderedProminent)

            case .requestingCode(let code, let verifyURL):
                VStack(spacing: 10) {
                    Text("Go to GitHub and enter the following code:")
                        .font(.caption)

                    HStack(spacing: 8) {
                        Text(code)
                            .font(.title3.monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThickMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                            .accessibilityLabel("Authentication code")

                        Button {
                            Platform.copyToClipboard(code)
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                didCopyCode = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    didCopyCode = false
                                }
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .help("Copy code to clipboard")
                        .accessibilityLabel("Copy code")
                    }

                    Button("Open GitHub") {
                        Platform.openURL(verifyURL)
                    }
                    .buttonStyle(.borderedProminent)

                    ProgressView("Waiting for authorization\u{2026}")
                        .padding(.top, 6)
                }
                .overlay(alignment: .top) {
                    if didCopyCode {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Copied!")
                                .font(.callout.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityHidden(true)
                        .padding(.top, -6)
                    }
                }

            case .waitingForApproval:
                ProgressView("Contacting GitHub\u{2026}")

            case .authenticated:
                ProgressView()

            case .failed(let reason):
                Label("Failed: \(reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Retry") {
                    auth.resetState()
                }
            }

            Button("Cancel") {
                auth.cancelSignIn()
            }
            .keyboardShortcut(.cancelAction)

            privacyNote
        }
        .padding(24)
        .frame(width: 320)
    }

    private var privacyNote: some View {
        VStack(spacing: 2) {
            Text("Signing in gives Luma\u{2019}s server your GitHub profile and email address.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PrivacyPolicyLink()
        }
        .font(.caption)
    }
}

extension View {
    func gitHubSignInSheet(auth: GitHubAuth, precedence: GitHubSignInSheetPrecedence) -> some View {
        modifier(GitHubSignInSheetHost(auth: auth, precedence: precedence))
    }
}

enum GitHubSignInSheetPrecedence {
    case ambient
    case foremost
}

private struct GitHubSignInSheetHost: ViewModifier {
    let auth: GitHubAuth
    let precedence: GitHubSignInSheetPrecedence

    @Environment(\.appearsActive) private var appearsActive
    @State private var hostID = UUID()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: isPresented) {
                GitHubSignInSheet(auth: auth)
            }
            .onAppear {
                GitHubSignInHosts.shared.register(hostID, precedence: precedence, appearsActive: appearsActive)
            }
            .onChange(of: appearsActive) {
                GitHubSignInHosts.shared.update(hostID, appearsActive: appearsActive)
            }
            .onChange(of: auth.isPresentingSignIn) {
                GitHubSignInHosts.shared.follow(signInPresentation: auth.isPresentingSignIn)
            }
            .onDisappear {
                GitHubSignInHosts.shared.release(hostID)
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { auth.isPresentingSignIn && GitHubSignInHosts.shared.presents(hostID) },
            set: { if !$0 { auth.dismissSignIn() } }
        )
    }
}

@Observable
@MainActor
private final class GitHubSignInHosts {
    static let shared = GitHubSignInHosts()

    private var hosts: [Host] = []
    private var chosenHostID: UUID?

    private struct Host {
        let id: UUID
        let precedence: GitHubSignInSheetPrecedence
        var appearsActive: Bool
    }

    func register(_ hostID: UUID, precedence: GitHubSignInSheetPrecedence, appearsActive: Bool) {
        hosts.append(Host(id: hostID, precedence: precedence, appearsActive: appearsActive))
    }

    func update(_ hostID: UUID, appearsActive: Bool) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[index].appearsActive = appearsActive
    }

    func follow(signInPresentation isPresenting: Bool) {
        chosenHostID = isPresenting ? (chosenHostID ?? hostBeingActedIn?.id) : nil
    }

    func release(_ hostID: UUID) {
        hosts.removeAll { $0.id == hostID }
    }

    func presents(_ hostID: UUID) -> Bool {
        presenterID == hostID
    }

    private var presenterID: UUID? {
        hosts.first { $0.id == chosenHostID }?.id ?? hostBeingActedIn?.id
    }

    private var hostBeingActedIn: Host? {
        let activeHosts = hosts.filter(\.appearsActive)
        let candidates = activeHosts.isEmpty ? hosts : activeHosts
        return candidates.last { $0.precedence == .foremost } ?? candidates.last
    }
}
