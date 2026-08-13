import LumaCore
import SwiftUI

/// Draws the icon a session shows in the sidebar when the process gave us
/// none, so the image sees what the reader sees. Rasterising belongs to the
/// frontend; the seed and palette behind it are LumaCore's.
@MainActor
enum PharoSessionIcon {
    static func base64PNG(for session: ProcessSession) -> String? {
        let renderer = ImageRenderer(
            content: IconPlaceholderView(
                seed: "\(session.deviceID)/\(session.processName)",
                displayName: session.processName,
                cornerRadius: 4
            )
            .frame(width: side, height: side))
        renderer.scale = 2

        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }

        return png.base64EncodedString()
    }

    private static let side: CGFloat = 32
}
