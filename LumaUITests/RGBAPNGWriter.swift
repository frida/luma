import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func writePNG(rgba bytes: [UInt8], size: CGSize, to url: URL) throws {
    let width = Int(size.width)
    let height = Int(size.height)
    let bytesPerRow = width * 4
    let expected = bytesPerRow * height
    if bytes.count < expected {
        throw HarnessError.protocolMismatch(
            "screenshot has \(bytes.count) bytes; expected \(expected) for \(width)x\(height)"
        )
    }

    let data = Data(bytes.prefix(expected))
    guard let provider = CGDataProvider(data: data as CFData) else {
        throw PNGWriteError.couldNotCreateProvider
    }
    let bitmapInfo: CGBitmapInfo = [
        CGBitmapInfo.byteOrder32Big,
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    ]
    guard let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw PNGWriteError.couldNotCreateImage
    }

    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw PNGWriteError.couldNotCreateDestination
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw PNGWriteError.finalizeFailed
    }
}

enum PNGWriteError: Error {
    case couldNotCreateProvider
    case couldNotCreateImage
    case couldNotCreateDestination
    case finalizeFailed
}
