import AppKit
import LumaCore
import SwiftUI

/// A window holding one shader effect, opened by the image so a snippet can
/// picture what it is working on. The image names an effect the build carries
/// and then feeds it; the drawing itself stays in the host.
@MainActor
final class PharoCanvasWindow {
    private static var shared: PharoCanvasWindow?

    /// Teaches `LumaCanvas` in the image how to reach a window here.
    static func install() {
        PharoCanvasHost.onShow = { effect in
            show(effect)
        }
        PharoCanvasHost.onReport = { activity in
            shared?.feed.activity = activity
        }
        PharoCanvasHost.onData = { values in
            shared?.feed.data = values
        }
        PharoCanvasHost.onClose = {
            shared?.window.close()
            shared = nil
        }
    }

    private static func show(_ effect: CanvasEffect) {
        if let existing = shared, existing.effect == effect {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        shared?.window.close()
        shared = PharoCanvasWindow(effect: effect)
        shared?.window.makeKeyAndOrderFront(nil)
    }

    let window: NSWindow

    private let effect: CanvasEffect
    private let feed = CanvasFeed()

    private init(effect: CanvasEffect) {
        self.effect = effect
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Canvas — \(effect.function)"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: PharoCanvasView(effect: effect, feed: feed))
    }
}

@MainActor
@Observable
final class CanvasFeed {
    var activity: Float = 0
    var data: [Float] = []
}

private struct PharoCanvasView: View {
    let effect: CanvasEffect
    let feed: CanvasFeed

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ShaderEffectView(
            program: .translated(metal: effect.metal, function: effect.function),
            scheme: colorScheme == .light ? 1.0 : 0.0,
            activity: feed.activity,
            data: feed.data
        )
    }
}
