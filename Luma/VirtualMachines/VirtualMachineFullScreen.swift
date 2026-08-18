import LumaCore
import SwiftUI

#if canImport(AppKit)
import AppKit

/// A guest shown on its own, filling the screen. The panel keeps its row, and
/// gets the display back when the window goes away.
@MainActor
enum VirtualMachineFullScreen {
    static func show(_ display: VirtualMachineDisplay, named name: String) {
        let window = NSWindow(
            contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = name
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = NSHostingView(rootView: VirtualMachineFullScreenView(display: display, name: name))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)

        windows[name] = window
        watchForEscape()
    }

    static func dismiss(named name: String) {
        guard let window = windows.removeValue(forKey: name) else { return }

        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        window.close()

        if windows.isEmpty, let escapeWatch {
            NSEvent.removeMonitor(escapeWatch)
            self.escapeWatch = nil
        }
    }

    /// The pointer belongs to the guest while it is grabbed, which puts the
    /// menu bar and the window's own buttons out of reach.
    private static func watchForEscape() {
        guard escapeWatch == nil else { return }

        escapeWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == escapeKeyCode else { return event }

            MainActor.assumeIsolated {
                for name in windows.keys where windows[name]?.isKeyWindow == true {
                    dismiss(named: name)
                }
            }
            return nil
        }
    }

    private static let escapeKeyCode: UInt16 = 53

    private static var windows: [String: NSWindow] = [:]
    private static var escapeWatch: Any?
}

private struct VirtualMachineFullScreenView: View {
    let display: VirtualMachineDisplay
    let name: String

    @State private var isPointerCaptured = false
    @State private var showsHint = true

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VirtualMachineDisplayView(display: display, capturing: .onAppear, isPointerCaptured: $isPointerCaptured)
        }
        .overlay(alignment: .top) { hint }
        .animation(.easeInOut(duration: 0.3), value: showsHint)
        .task(id: isPointerCaptured) {
            showsHint = true
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            showsHint = false
        }
    }

    @ViewBuilder
    private var hint: some View {
        if showsHint {
            Text(isPointerCaptured ? capturedHint : releasedHint)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.65), in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 24)
                .transition(.opacity)
        }
    }

    private let capturedHint = "Hold Control-Option to release the pointer · Escape leaves full screen"
    private let releasedHint = "Escape leaves full screen"
}
#endif
