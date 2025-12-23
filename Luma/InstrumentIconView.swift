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
                fileImage(url: url)
            }
        }
    }

    @ViewBuilder
    private func fileImage(url: URL) -> some View {
        #if canImport(AppKit)
            if let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: pointSize, height: pointSize)
            } else {
                fallback
            }
        #elseif canImport(UIKit)
            if let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: pointSize, height: pointSize)
            } else {
                fallback
            }
        #else
            fallback
        #endif
    }

    private var fallback: some View {
        Image(systemName: "questionmark.square.dashed")
            .font(.system(size: pointSize))
    }
}
