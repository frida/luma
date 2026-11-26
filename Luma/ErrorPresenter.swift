import SwiftUI

struct UIError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ErrorPresenter {
    var present: (_ title: String, _ message: String) -> Void
}

private struct ErrorPresenterKey: EnvironmentKey {
    static let defaultValue = ErrorPresenter { title, message in
        assertionFailure("No view hosts error presentation, so “\(title): \(message)” would be lost")
    }
}

extension EnvironmentValues {
    var errorPresenter: ErrorPresenter {
        get { self[ErrorPresenterKey.self] }
        set { self[ErrorPresenterKey.self] = newValue }
    }
}

struct ErrorPopoverHost: ViewModifier {
    @State private var uiError: UIError?

    func body(content: Content) -> some View {
        content
            .environment(
                \.errorPresenter,
                ErrorPresenter { title, message in
                    uiError = UIError(title: title, message: message)
                }
            )
            .popover(item: $uiError, arrowEdge: .top) { err in
                VStack(alignment: .leading, spacing: 8) {
                    Text(err.title).font(.headline)
                    Text(err.message).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Spacer()
                        Button("OK") { uiError = nil }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
                .frame(width: 360)
            }
    }
}

private struct ErrorAlertHost: ViewModifier {
    @State private var uiError: UIError?

    func body(content: Content) -> some View {
        content
            .environment(\.errorPresenter, ErrorPresenter { title, message in uiError = UIError(title: title, message: message) })
            .alert(uiError?.title ?? "", isPresented: Binding(get: { uiError != nil }, set: { if !$0 { uiError = nil } }), presenting: uiError) { _ in
                Button("OK") { uiError = nil }
            } message: { error in
                Text(error.message)
            }
    }
}

extension View {
    func errorPopoverHost() -> some View { modifier(ErrorPopoverHost()) }

    func errorAlertHost() -> some View { modifier(ErrorAlertHost()) }
}
