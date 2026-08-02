import ImageIO
import LumaCore
import SwiftUI
import UniformTypeIdentifiers

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

        guard let image = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return (data as Data).base64EncodedString()
    }

    private static let side: CGFloat = 32
}
