import Foundation
import Frida
import Gdk
import GLib
import Gtk

enum IconPixbuf {
    static func makeTexture(from icon: Frida.Icon) -> Gdk.Texture? {
        switch icon {
        case let .rgba(width, height, pixels):
            return makeRGBATexture(width: width, height: height, pixels: pixels)
        case let .png(data):
            return makePNGTexture(data: data)
        }
    }

    static func makeTexture(fromPNGData data: Foundation.Data) -> Gdk.Texture? {
        makePNGTexture(data: Array(data))
    }

    /// Build a Gdk.Texture from arbitrary encoded image bytes (PNG, JPEG,
    /// WebP, GIF — anything GDK's pixbuf loader recognizes). The name-
    /// cousin `makeTexture(fromPNGData:)` is a legacy alias.
    static func makeTexture(fromEncodedData data: Foundation.Data) -> Gdk.Texture? {
        makePNGTexture(data: Array(data))
    }

    static func makeImage(from icon: Frida.Icon, pixelSize: Int) -> Gtk.Image? {
        guard let texture = makeTexture(from: icon) else { return nil }
        return makeImage(from: texture, pixelSize: pixelSize)
    }

    static func makeImage(fromPNGData data: Foundation.Data, pixelSize: Int) -> Gtk.Image? {
        guard let texture = makeTexture(fromPNGData: data) else { return nil }
        return makeImage(from: texture, pixelSize: pixelSize)
    }

    static func makeImage(from texture: Gdk.Texture, pixelSize: Int) -> Gtk.Image {
        let image = Gtk.Image(paintable: texture)
        image.pixelSize = pixelSize
        return image
    }

    private static func makeRGBATexture(width: Int, height: Int, pixels: [UInt8]) -> Gdk.Texture? {
        guard width > 0, height > 0 else { return nil }
        let rowstride = width * 4
        guard pixels.count >= rowstride * height else { return nil }
        let bytes = pixels.withUnsafeBufferPointer { buf in
            Bytes(data: UnsafeRawPointer(buf.baseAddress!), size: pixels.count)
        }
        let builder = Gdk.MemoryTextureBuilder()
        builder.set(bytes: bytes)
        builder.set(format: .r8g8b8a8)
        builder.set(width: width)
        builder.set(height: height)
        builder.set(stride: rowstride)
        guard let ref = builder.build() else { return nil }
        return Gdk.Texture(ref.texture_ptr)
    }

    private static func makePNGTexture(data: [UInt8]) -> Gdk.Texture? {
        guard !data.isEmpty else { return nil }
        let bytes = data.withUnsafeBufferPointer { buf in
            Bytes(data: UnsafeRawPointer(buf.baseAddress!), size: data.count)
        }
        return try? Gdk.Texture(bytes: bytes)
    }
}
