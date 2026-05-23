import CoreGraphics
import Foundation
import ImageIO
import LumaCore
import UniformTypeIdentifiers

struct HostImageProcessor: ImageProcessor {
    func scaleDown(data: Data, mediaType: String, maxDimension: Int) -> ProcessedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCache: false,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ProcessedImage(
            mediaType: "image/png",
            data: mutableData as Data,
            width: scaled.width,
            height: scaled.height
        )
    }
}
