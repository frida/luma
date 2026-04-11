import CGtk
import Foundation
import GLibObject
import Gtk

#if canImport(AppKit)
import AppKit
#endif

// All public state lives behind a lock so it can be touched from nonisolated
// deinit (which Swift 6 considers off-actor) without crashing strict-concurrency
// checks. The actual GTK calls all happen on the main thread anyway: subscribe
// is invoked from @MainActor code, and unsubscribe from deinit just disconnects
// a signal handler — gtk_settings_get_default + g_signal_handler_disconnect are
// thread-safe in GTK4.

enum ThemeWatcher {
    @MainActor
    static func install() {
        #if canImport(AppKit)
        // GTK4's GdkMacos backend does not push NSApp.effectiveAppearance into
        // GtkSettings, so neither the GTK theme nor our ThemeWatcher subscribers
        // ever notice macOS appearance changes. Mirror it ourselves: read the
        // current appearance now, observe future changes via KVO, and write it
        // into gtk-application-prefer-dark-theme so GTK and our subscribers
        // both react.
        macAppearanceBridge.start()
        #endif
    }

    @MainActor
    static func isDarkMode() -> Bool {
        guard let settings = gtk_settings_get_default() else { return false }
        let object = UnsafeMutableRawPointer(settings).assumingMemoryBound(to: GObject.self)
        if readBool(object: object, property: "gtk-application-prefer-dark-theme") {
            return true
        }
        return readString(object: object, property: "gtk-theme-name")?
            .localizedCaseInsensitiveContains("dark") ?? false
    }

    @MainActor
    private static func readBool(
        object: UnsafeMutablePointer<GObject>,
        property: String
    ) -> Bool {
        var value = GValue()
        g_value_init(&value, GType.boolean)
        g_object_get_property(object, property, &value)
        let result = g_value_get_boolean(&value) != 0
        g_value_unset(&value)
        return result
    }

    @MainActor
    private static func readString(
        object: UnsafeMutablePointer<GObject>,
        property: String
    ) -> String? {
        var value = GValue()
        g_value_init(&value, GType.string)
        g_object_get_property(object, property, &value)
        defer { g_value_unset(&value) }
        guard let cString = g_value_get_string(&value) else { return nil }
        return String(cString: cString)
    }

    @MainActor
    fileprivate static func writeBool(
        object: UnsafeMutablePointer<GObject>,
        property: String,
        value: Bool
    ) {
        var v = GValue()
        g_value_init(&v, GType.boolean)
        g_value_set_boolean(&v, value ? gboolean(1) : gboolean(0))
        g_object_set_property(object, property, &v)
        g_value_unset(&v)
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
        let signals = [
            "notify::gtk-theme-name",
            "notify::gtk-application-prefer-dark-theme",
        ]
        var handlerIDs: [gulong] = []
        for signal in signals {
            let handlerID = g_signal_connect_data(
                settings,
                signal,
                unsafeBitCast(themeChangedCallback, to: GCallback.self),
                userData,
                nil,
                GConnectFlags(rawValue: 0)
            )
            handlerIDs.append(handlerID)
        }
        State.lock.withLock {
            State.handlersForToken[token] = handlerIDs
        }
        return gulong(token)
    }

    nonisolated static func unsubscribe(handlerID: gulong) {
        let token = UInt(handlerID)
        let realIDs: [gulong] = State.lock.withLock {
            State.callbacks.removeValue(forKey: token)
            return State.handlersForToken.removeValue(forKey: token) ?? []
        }
        guard !realIDs.isEmpty, let settings = gtk_settings_get_default() else { return }
        for id in realIDs {
            g_signal_handler_disconnect(settings, id)
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

#if canImport(AppKit)

@MainActor
private let macAppearanceBridge = MacAppearanceBridge()

@MainActor
private final class MacAppearanceBridge: NSObject {
    private var observation: NSKeyValueObservation?

    func start() {
        guard observation == nil else { return }
        sync()
        observation = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.sync()
                }
            }
        }
    }

    private func sync() {
        guard let settings = gtk_settings_get_default() else { return }
        let object = UnsafeMutableRawPointer(settings).assumingMemoryBound(to: GObject.self)
        let appearance = NSApplication.shared.effectiveAppearance
        let match = appearance.bestMatch(from: [.aqua, .darkAqua])
        let isDark = match == .darkAqua
        ThemeWatcher.writeBool(
            object: object,
            property: "gtk-application-prefer-dark-theme",
            value: isDark
        )
    }
}

#endif
