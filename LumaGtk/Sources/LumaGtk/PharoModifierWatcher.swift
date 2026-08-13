import Adw
import Gdk
import Gtk

/// Publishes the keyboard modifiers currently held, so a pane's corner button
/// can morph to say what it will do — collapse while the primary key is down,
/// close while it and Shift are. Mirrors the flags monitor the SwiftUI inspector
/// keeps. One capture-phase controller on the window sees every modifier change
/// regardless of where focus sits; panes subscribe while they are on screen.
@MainActor
enum PharoModifierWatcher {
    private(set) static var current = Gdk.ModifierType(rawValue: 0)

    static var primaryHeld: Bool {
        current.contains(.controlMask) || current.contains(.metaMask)
    }

    static var shiftHeld: Bool { current.contains(.shiftMask) }

    static func install(on window: Adw.ApplicationWindow) {
        guard !installed else { return }
        installed = true
        let keys = EventControllerKey()
        keys.propagationPhase = .capture
        keys.onModifiers { _, state in
            MainActor.assumeIsolated { PharoModifierWatcher.update(state) }
            return false
        }
        window.install(controller: keys)

        // macOS drops the release of Command now and then, so a held state can
        // linger; whenever focus leaves the window -- opening a menu, switching
        // apps -- take that as the keys being let go.
        let focus = EventControllerFocus()
        focus.onLeave { _ in
            MainActor.assumeIsolated { PharoModifierWatcher.reset() }
        }
        window.install(controller: focus)
    }

    static func reset() {
        update(Gdk.ModifierType(rawValue: 0))
    }

    static func subscribe(_ onChange: @escaping () -> Void) -> UInt {
        let token = nextToken
        nextToken += 1
        subscribers[token] = onChange
        return token
    }

    static func unsubscribe(_ token: UInt) {
        subscribers[token] = nil
    }

    private static func update(_ state: Gdk.ModifierType) {
        guard state != current else { return }
        current = state
        for notify in subscribers.values { notify() }
    }

    private static var installed = false
    private static var nextToken: UInt = 1
    private static var subscribers: [UInt: () -> Void] = [:]
}
