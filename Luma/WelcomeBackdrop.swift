import SwiftUI

struct WelcomeBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ShaderEffectView(
            vertexFunction: "welcomeBackdropVertex",
            fragmentFunction: "welcomeBackdropFragment",
            scheme: colorScheme == .light ? 1.0 : 0.0
        )
    }
}
