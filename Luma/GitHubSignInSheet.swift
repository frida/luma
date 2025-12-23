import SwiftUI

struct GitHubSignInSheet: View {
    @ObservedObject var workspace: Workspace
    @State private var didCopyCode = false

    var body: some View {
        VStack(spacing: 16) {
            Image("GitHubMark")
                .resizable()
                .frame(width: 40, height: 40)

            Text("Sign in with GitHub")
                .font(.headline)

            switch workspace.authState {
            case .signedOut:
                Button("Sign in with GitHub") {
                    Task {
                        await GitHubAuthenticator.shared.beginSignIn(workspace: workspace)
                    }
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

                    ProgressView("Waiting for authorization…")
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
                ProgressView("Contacting GitHub…")

            case .authenticated:
                Label("Signed in!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Continue") {
                    workspace.authState = .signedOut
                    workspace.startCollaboration()
                }

            case .failed(let reason):
                Label("Failed: \(reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Retry") {
                    workspace.authState = .signedOut
                }
            }

            Button("Cancel") {
                GitHubAuthenticator.shared.cancel()
                workspace.isAuthSheetPresented = false
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 320)
        .onChange(of: workspace.authState) { _, newValue in
            if case .authenticated = newValue {
                workspace.isAuthSheetPresented = false
                workspace.authState = .signedOut
                if workspace.githubToken != nil {
                    workspace.startCollaboration()
                }
            }
        }
    }
}
