import SwiftUI

@available(macOS 14.0, iOS 17.0, *)
extension View {
    func keyboardSearch(
        text: Binding<String>,
        focus: FocusState<Bool>.Binding
    ) -> some View {
        self.modifier(KeyboardSearchModifier(text: text, searchFieldFocus: focus))
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct KeyboardSearchModifier: ViewModifier {
    @Binding var text: String
    var searchFieldFocus: FocusState<Bool>.Binding

    @FocusState private var hasKeyboardFocus: Bool

    func body(content: Content) -> some View {
        content
            .focused($hasKeyboardFocus)
            .focusEffectDisabled()
            .onAppear {
                hasKeyboardFocus = true
            }
            .onKeyPress { press in
                guard !searchFieldFocus.wrappedValue else { return .ignored }

                guard press.modifiers.isEmpty else { return .ignored }

                let chars = press.characters
                guard !chars.isEmpty else { return .ignored }
                let isAlphanumeric = text.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil
                guard isAlphanumeric else { return .ignored }

                DispatchQueue.main.async {
                    text.append(contentsOf: chars)
                    hasKeyboardFocus = false
                    searchFieldFocus.wrappedValue = true
                }

                return .handled
            }
    }
}
