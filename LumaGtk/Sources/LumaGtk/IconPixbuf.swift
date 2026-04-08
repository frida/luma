import Foundation
import Frida
import GdkPixBuf
import GLib
import Gtk

enum IconPixbuf {
    static func makePixbuf(from icon: Frida.Icon) -> Pixbuf? {
        switch icon {
        case let .rgba(width, height, pixels):
            return makeRGBAPixbuf(width: width, height: height, pixels: pixels)
        case let .png(data):
            return makePNGPixbuf(data: data)
        }
    }

    static func makePixbuf(fromPNGData data: Foundation.Data) -> Pixbuf? {
        makePNGPixbuf(data: Array(data))
    }

    static func makeImage(from icon: Frida.Icon, pixelSize: Int) -> Gtk.Image? {
        guard let pixbuf = makePixbuf(from: icon) else { return nil }
        return makeImage(from: pixbuf, pixelSize: pixelSize)
    }

    static func makeImage(fromPNGData data: Foundation.Data, pixelSize: Int) -> Gtk.Image? {
        guard let pixbuf = makePixbuf(fromPNGData: data) else { return nil }
        return makeImage(from: pixbuf, pixelSize: pixelSize)
    }

    static func makeImage(from pixbuf: Pixbuf, pixelSize: Int) -> Gtk.Image {
        let image = Gtk.Image(pixbuf: pixbuf)
        image.pixelSize = pixelSize
        return image
    }

    private static func makeRGBAPixbuf(width: Int, height: Int, pixels: [UInt8]) -> Pixbuf? {
        guard width > 0, height > 0 else { return nil }
        let rowstride = width * 4
        guard pixels.count >= rowstride * height else { return nil }
        let bytes = pixels.withUnsafeBufferPointer { buf -> Bytes in
            Bytes(data: UnsafeRawPointer(buf.baseAddress!), size: pixels.count)
        }
        return Pixbuf(
            bytes: bytes,
            colorspace: Colorspace.rgb,
            hasAlpha: true,
            bitsPerSample: 8,
            width: width,
            height: height,
            rowstride: rowstride
        )
    }

    private static func makePNGPixbuf(data: [UInt8]) -> Pixbuf? {
        guard !data.isEmpty else { return nil }
        let loader = PixbufLoader()
        do {
            _ = try data.withUnsafeBufferPointer { buf in
                try loader.write(buf: buf.baseAddress!, count: data.count)
            }
            _ = try loader.close()
        } catch {
            return nil
        }
        guard let ref = loader.getPixbuf() else { return nil }
        return Pixbuf(retainingRaw: UnsafeRawPointer(ref.pixbuf_ptr))
    }
}
