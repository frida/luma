#if canImport(UIKit)
import SwiftUI
import UIKit

struct KeyboardAdaptiveModifier: ViewModifier {
    @State private var bottomInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, bottomInset)
            .animation(.easeOut(duration: 0.2), value: bottomInset)
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            ) { note in
                update(from: note)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            ) { _ in
                bottomInset = 0
            }
    }

    private func update(from note: Notification) {
        guard let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: \.isKeyWindow)
        else { return }
        let screenHeight = window.bounds.height
        let safeAreaBottom = window.safeAreaInsets.bottom
        let overlap = max(0, screenHeight - endFrame.origin.y - safeAreaBottom)
        bottomInset = overlap
    }
}

extension View {
    func keyboardAdaptive() -> some View {
        modifier(KeyboardAdaptiveModifier())
    }
}
#else
import SwiftUI

extension View {
    func keyboardAdaptive() -> some View { self }
}
#endif
