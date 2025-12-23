import SwiftUI

enum Platform {
    static func copyToClipboard(_ string: String) {
        #if canImport(AppKit)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(string, forType: .string)
        #elseif canImport(UIKit)
            UIPasteboard.general.string = string
        #endif
    }

    static func openURL(_ url: URL) {
        #if canImport(AppKit)
            NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
            UIApplication.shared.open(url)
        #endif
    }
}

extension View {
    @ViewBuilder
    func platformLinkButtonStyle() -> some View {
        #if os(macOS)
            self.buttonStyle(.link)
        #else
            self.buttonStyle(.plain).foregroundStyle(.tint)
        #endif
    }
}

struct PlatformHSplit<Left: View, Right: View>: View {
    let left: Left
    let right: Right

    init(@ViewBuilder content: () -> TupleView<(Left, Right)>) {
        let tuple = content().value
        self.left = tuple.0
        self.right = tuple.1
    }

    var body: some View {
        #if os(macOS)
            HSplitView {
                left
                right
            }
        #else
            HStack(spacing: 0) {
                left
                Divider()
                right
            }
        #endif
    }
}
