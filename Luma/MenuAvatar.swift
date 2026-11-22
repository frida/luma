import SwiftUI

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

struct MenuAvatar: View {
    let url: URL?
    let pointSize: CGFloat

    @State private var picture: PlatformImage?

    var body: some View {
        Group {
            if let picture {
                Image(platformImage: picture)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .task(id: url) {
            guard let url else { return }
            picture = await Self.picture(at: url, pointSize: pointSize)
        }
    }

    private static func picture(at url: URL, pointSize: CGFloat) async -> PlatformImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url), let source = PlatformImage(data: data) else { return nil }
        return circle(of: source, pointSize: pointSize)
    }

    private static func circle(of source: PlatformImage, pointSize: CGFloat) -> PlatformImage {
        let bounds = CGRect(x: 0, y: 0, width: pointSize, height: pointSize)
        #if canImport(AppKit)
            return NSImage(size: bounds.size, flipped: false) { rect in
                NSBezierPath(ovalIn: rect).addClip()
                source.draw(in: filling(rect, with: source.size))
                return true
            }
        #else
            return UIGraphicsImageRenderer(size: bounds.size).image { _ in
                UIBezierPath(ovalIn: bounds).addClip()
                source.draw(in: filling(bounds, with: source.size))
            }
        #endif
    }

    private static func filling(_ rect: CGRect, with size: CGSize) -> CGRect {
        let scale = max(rect.width / size.width, rect.height / size.height)
        let filled = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - filled.width / 2, y: rect.midY - filled.height / 2, width: filled.width, height: filled.height)
    }
}
