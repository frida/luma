import Adw
import CGLib
import Foundation
import GLibObject
import Gtk

// All public state lives behind a lock so it can be touched from nonisolated
// deinit (which Swift 6 considers off-actor) without crashing strict-concurrency
// checks. The actual GTK calls all happen on the main thread anyway: subscribe
// is invoked from @MainActor code, and unsubscribe from deinit just disconnects
// a signal handler — AdwStyleManager + g_signal_handler_disconnect are
// thread-safe in GTK4.

enum ThemeWatcher {
    @MainActor
    static func isDarkMode() -> Bool {
        Adw.StyleManager.getDefault().dark
    }

    @MainActor
    static func subscribe<Owner: AnyObject>(
        owner: Owner,
        onChange: @escaping @MainActor (Owner) -> Void
    ) -> gulong {
        let manager = Adw.StyleManager.getDefault()!
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
            manager.style_manager_ptr,
            "notify::dark",
            unsafeBitCast(themeChangedCallback, to: GCallback.self),
            userData,
            nil,
            GConnectFlags(rawValue: 0)
        )
        State.lock.withLock {
            State.handlersForToken[token] = [handlerID]
        }
        return gulong(token)
    }

    nonisolated static func unsubscribe(handlerID: gulong) {
        let token = UInt(handlerID)
        let realIDs: [gulong] = State.lock.withLock {
            State.callbacks.removeValue(forKey: token)
            return State.handlersForToken.removeValue(forKey: token) ?? []
        }
        guard !realIDs.isEmpty else { return }
        MainActor.assumeIsolated {
            let manager = Adw.StyleManager.getDefault()!
            for id in realIDs {
                g_signal_handler_disconnect(manager.style_manager_ptr, id)
            }
        }
    }

    fileprivate static func dispatch(token: UInt) {
        let callback = State.lock.withLock { State.callbacks[token] }
        callback?()
    }

    private enum State {
        nonisolated(unsafe) static var nextToken: UInt = 1
        nonisolated(unsafe) static var callbacks: [UInt: () -> Void] = [:]
        nonisolated(unsafe) static var handlersForToken: [UInt: [gulong]] = [:]
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
