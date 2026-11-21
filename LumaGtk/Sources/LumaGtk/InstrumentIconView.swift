import Foundation
import Gtk
import LumaCore

@MainActor
enum InstrumentIconView {
    static func makeImage(for icon: InstrumentIcon, pixelSize: Int) -> Image {
        switch icon {
        case .symbolic(let id):
            let image = Image(iconName: InstrumentIconCatalog.concept(forID: id).symbolicIcon)
            image.pixelSize = pixelSize
            return image
        case .pixels(let data):
            return IconPixbuf.makeImage(fromPNGData: data, pixelSize: pixelSize)
                ?? fallbackImage(pixelSize: pixelSize)
        }
    }

    static func makeImage(for item: StoreItem, from storefront: Storefront, pixelSize: Int) -> Widget {
        switch item.icon {
        case .symbolic(let id):
            return makeImage(for: .symbolic(id), pixelSize: pixelSize)
        case .pixels:
            return makeFetchedImage(for: item, from: storefront, pixelSize: pixelSize)
        }
    }

    private static func makeFetchedImage(for item: StoreItem, from storefront: Storefront, pixelSize: Int) -> Box {
        let holder = Box(orientation: .horizontal, spacing: 0)
        let placeholder = makeImage(for: .symbolic(InstrumentIconCatalog.default.id), pixelSize: pixelSize)
        holder.append(child: placeholder)
        Task { @MainActor in
            let icon = await storefront.icon(of: item)
            holder.remove(child: placeholder)
            holder.append(child: makeImage(for: icon, pixelSize: pixelSize))
        }
        return holder
    }

    private static func fallbackImage(pixelSize: Int) -> Image {
        let image = Image(iconName: "application-x-executable-symbolic")
        image.pixelSize = pixelSize
        return image
    }
}
