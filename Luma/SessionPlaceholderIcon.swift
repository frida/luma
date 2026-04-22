import LumaCore
import SwiftUI

struct SessionPlaceholderIcon: View {
    let seed: String
    let displayName: String
    var cornerRadius: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Text(SessionPlaceholder.initials(for: displayName))
                    .font(.system(size: side * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .shadow(color: Color.black.opacity(0.15), radius: 1, y: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var gradientColors: [Color] {
        let palette = SessionPlaceholder.palette(for: seed)
        return [
            Color(
                hue: palette.primaryHue,
                saturation: palette.primarySaturation,
                brightness: palette.primaryBrightness
            ),
            Color(
                hue: palette.secondaryHue,
                saturation: palette.secondarySaturation,
                brightness: palette.secondaryBrightness
            ),
        ]
    }
}
