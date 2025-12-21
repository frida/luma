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
    static let defaultValue = ErrorPresenter(present: { _, _ in })
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

extension View {
    func errorPopoverHost() -> some View { modifier(ErrorPopoverHost()) }
}
