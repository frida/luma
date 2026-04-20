import SwiftUI

extension Color {
    static var platformWindowBackground: Color {
        #if canImport(AppKit)
            return Color(NSColor.windowBackgroundColor)
        #elseif canImport(UIKit)
            return Color(UIColor.systemBackground)
        #else
            return Color(.background)
        #endif
    }

    static var jsTypeLabel: Color {
        #if canImport(UIKit)
            return Color(uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.cyan
                    : UIColor(red: 0.0, green: 0.45, blue: 0.65, alpha: 1.0)
            })
        #elseif canImport(AppKit)
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark
                    ? NSColor.cyan
                    : NSColor(calibratedRed: 0.0, green: 0.45, blue: 0.65, alpha: 1.0)
            })
        #else
            return .cyan
        #endif
    }
}

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
