import SwiftUI

#if canImport(AppKit)
    import AppKit

    typealias PlatformFont = NSFont
    typealias PlatformColor = NSColor
#elseif canImport(UIKit)
    import UIKit

    typealias PlatformFont = UIFont
    typealias PlatformColor = UIColor
#endif

extension PlatformColor {
    static var platformLabel: PlatformColor {
        #if canImport(AppKit)
            .labelColor
        #else
            .label
        #endif
    }
}
