import SwiftUI

#if canImport(AppKit)
    import AppKit

    typealias PlatformImage = NSImage

    extension Image {
        init(platformImage: PlatformImage) {
            self.init(nsImage: platformImage)
        }
    }
#elseif canImport(UIKit)
    import UIKit

    typealias PlatformImage = UIImage

    extension Image {
        init(platformImage: PlatformImage) {
            self.init(uiImage: platformImage)
        }
    }
#endif

extension Image {
    init?(platformImageData data: Data) {
        guard let image = PlatformImage(data: data) else { return nil }
        self.init(platformImage: image)
    }
}
