import CGtk
import Foundation
import GLibObject
import Gtk

// All public state lives behind a lock so it can be touched from nonisolated
// deinit (which Swift 6 considers off-actor) without crashing strict-concurrency
// checks. The actual GTK calls all happen on the main thread anyway: subscribe
// is invoked from @MainActor code, and unsubscribe from deinit just disconnects
// a signal handler — gtk_settings_get_default + g_signal_handler_disconnect are
// thread-safe in GTK4.

enum ThemeWatcher {
    @MainActor
    static func isDarkMode() -> Bool {
        guard let settings = Settings.getDefault() else { return false }
        let value = settings.get(property: .gtkThemeName)
        guard let name = value.string else { return false }
        return name.localizedCaseInsensitiveContains("dark")
    }

    @MainActor
    static func subscribe<Owner: AnyObject>(
        owner: Owner,
        onChange: @escaping @MainActor (Owner) -> Void
    ) -> gulong {
        guard let settings = gtk_settings_get_default() else { return 0 }
        let token = State.lock.withLock {
            let token = State.nextToken
            State.nextToken += 1
            State.callbacks[token] = { [weak owner] in
                guard let owner else { return }
                onChange(owner)
            }
            return token
        }
        let userData = UnsafeMutableRawPointer(bitPattern: token)
        let handlerID = g_signal_connect_data(
            settings,
            "notify::gtk-theme-name",
            unsafeBitCast(themeChangedCallback, to: GCallback.self),
            userData,
            nil,
            GConnectFlags(rawValue: 0)
        )
        State.lock.withLock {
            State.handlerForToken[token] = handlerID
        }
        return gulong(token)
    }

    nonisolated static func unsubscribe(handlerID: gulong) {
        let token = UInt(handlerID)
        let realID: gulong? = State.lock.withLock {
            State.callbacks.removeValue(forKey: token)
            return State.handlerForToken.removeValue(forKey: token)
        }
        guard let realID, let settings = gtk_settings_get_default() else { return }
        g_signal_handler_disconnect(settings, realID)
    }

    fileprivate static func dispatch(token: UInt) {
        let callback = State.lock.withLock { State.callbacks[token] }
        callback?()
    }

    private enum State {
        nonisolated(unsafe) static var nextToken: UInt = 1
        nonisolated(unsafe) static var callbacks: [UInt: () -> Void] = [:]
        nonisolated(unsafe) static var handlerForToken: [UInt: gulong] = [:]
        static let lock = NSLock()
    }
}

extension NSLock {
    fileprivate func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}

private let themeChangedCallback:
    @convention(c) (
        UnsafeMutableRawPointer,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?
    ) -> Void = { _, _, userData in
        guard let userData else { return }
        let token = UInt(bitPattern: userData)
        MainActor.assumeIsolated {
            ThemeWatcher.dispatch(token: token)
        }
    }
