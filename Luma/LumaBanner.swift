import SwiftUI

struct LumaBanner<Content: View>: View {
    let style: LumaBannerStyle
    let content: () -> Content

    init(
        style: LumaBannerStyle,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.style = style
        self.content = content
    }

    var body: some View {
        HStack {
            content()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(style.backgroundColor)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(style.borderColor),
            alignment: .bottom
        )
    }
}

enum LumaBannerStyle {
    case info
    case warning
    case error

    var backgroundColor: Color {
        switch self {
        case .info:
            return .yellow.opacity(0.15)
        case .warning:
            return .orange.opacity(0.15)
        case .error:
            return .red.opacity(0.15)
        }
    }

    var borderColor: Color {
        switch self {
        case .info:
            return .yellow.opacity(0.3)
        case .warning:
            return .orange.opacity(0.4)
        case .error:
            return .red.opacity(0.4)
        }
    }
}
