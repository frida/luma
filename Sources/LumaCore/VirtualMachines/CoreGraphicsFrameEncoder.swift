#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CoreGraphicsFrameEncoder {
    public static func install() {
        VirtualMachineFrameEncoder.png = { frame, width in
            png(of: frame, width: width)
        }
    }

    private static func png(of frame: VirtualMachineFrame, width: Int) -> Data? {
        guard let image = image(of: frame), let scaled = scaled(image, toWidth: width) else { return nil }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? buffer as Data : nil
    }

    private static func image(of frame: VirtualMachineFrame) -> CGImage? {
        let alpha: CGImageAlphaInfo = frame.format == .bgra8888 ? .premultipliedFirst : .noneSkipFirst
        guard let provider = CGDataProvider(data: frame.withPixels { Data($0) } as CFData) else { return nil }
        return CGImage(
            width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func scaled(_ image: CGImage, toWidth targetWidth: Int) -> CGImage? {
        guard targetWidth < image.width else { return image }
        let targetHeight = max(1, image.height * targetWidth / image.width)
        guard
            let context = CGContext(
                data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }
}
#endif
