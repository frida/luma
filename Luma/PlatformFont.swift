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

extension Font {
    static let monospacedContent = Font.system(.body, design: .monospaced)
}

extension PlatformFont {
    static var monospacedContent: PlatformFont {
        .monospacedSystemFont(ofSize: preferredFont(forTextStyle: .body).pointSize, weight: .regular)
    }
}

extension PlatformColor {
    static var platformLabel: PlatformColor {
        #if canImport(AppKit)
            .labelColor
        #else
            .label
        #endif
    }
}
