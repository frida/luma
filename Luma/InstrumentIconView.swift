import SwiftUI
import LumaCore

struct InstrumentIconView: View {
    let icon: InstrumentIcon
    var pointSize: CGFloat = 12

    var body: some View {
        switch icon {
        case .symbolic(let id):
            Image(systemName: InstrumentIconCatalog.concept(forID: id).sfSymbol)
                .font(.system(size: pointSize))
        case .pixels(let data):
            pixelsImage(data: data)
        }
    }

    @ViewBuilder
    private func pixelsImage(data: Data) -> some View {
        if let image = Image(platformImageData: data) {
            image
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: pointSize, height: pointSize)
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(systemName: "questionmark.square.dashed")
            .font(.system(size: pointSize))
    }
}
