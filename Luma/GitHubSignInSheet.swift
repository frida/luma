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
        }
        .padding(24)
        .frame(width: 320)
    }
}
