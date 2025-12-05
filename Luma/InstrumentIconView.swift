import SwiftUI

struct InstrumentIconView: View {
    let icon: InstrumentIcon
    var pointSize: CGFloat = 12

    var body: some View {
        Group {
            switch icon {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: pointSize))

            case .file(let url):
                if let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: pointSize, height: pointSize)
                } else {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: pointSize))
                }
            }
        }
    }
}
