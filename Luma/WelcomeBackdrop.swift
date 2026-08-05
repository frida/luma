import SwiftUI

struct WelcomeBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ShaderEffectView(
            fragmentFunction: "welcomeBackdropFragment",
            scheme: colorScheme == .light ? 1.0 : 0.0
        )
    }
}
