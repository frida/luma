import CGtk
import CLuma
import Foundation
import GLibObject
import Gtk
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
        // GtkSettings, so neither the GTK chrome nor our subscribers ever
        // notice macOS appearance changes. Mirror it ourselves into the
        // appropriate color scheme property.
        macAppearanceBridge.start()
        #endif
    }

    @MainActor
    static func isDarkMode() -> Bool {
        guard let settings = gtk_settings_get_default() else { return false }
        let object = UnsafeMutableRawPointer(settings).assumingMemoryBound(to: GObject.self)
        return readIsDark(object: object)
    }

    @MainActor
    private static func readIsDark(
        object: UnsafeMutablePointer<GObject>
    ) -> Bool {
        if hasColorSchemeProperty {
            var v = GValue()
            g_value_init(&v, colorSchemeGType)
            g_object_get_property(object, colorSchemePropertyName, &v)
            let raw = g_value_get_enum(&v)
            g_value_unset(&v)
            // InterfaceColorScheme: 0 = default, 1 = light, 2 = dark
            return raw == 2
        }
        var v = GValue()
        g_value_init(&v, GType(luma_g_type_boolean()))
        g_object_get_property(object, preferDarkPropertyName, &v)
        let isDark = g_value_get_boolean(&v) != 0
        g_value_unset(&v)
        return isDark
    }

    @MainActor
    fileprivate static func writeIsDark(
        object: UnsafeMutablePointer<GObject>,
        dark: Bool
    ) {
        if hasColorSchemeProperty {
            var v = GValue()
            g_value_init(&v, colorSchemeGType)
            // InterfaceColorScheme: 1 = light, 2 = dark
            g_value_set_enum(&v, dark ? 2 : 1)
            g_object_set_property(object, colorSchemePropertyName, &v)
            g_value_unset(&v)
        } else {
            var v = GValue()
            g_value_init(&v, GType(luma_g_type_boolean()))
            g_value_set_boolean(&v, dark ? 1 : 0)
            g_object_set_property(object, preferDarkPropertyName, &v)
            g_value_unset(&v)
        }
    }

    private static let colorSchemePropertyName = "gtk-interface-color-scheme"
    private static let preferDarkPropertyName = "gtk-application-prefer-dark-theme"

    /// `gtk-interface-color-scheme` is GTK 4.20+. We discover both whether
    /// the property exists and its enum GType from the property spec — no
    /// dlsym needed (and `dlsym(nil, …)` doesn't even work on macOS, where
    /// the default-namespace handle is `RTLD_DEFAULT == -2`, not `NULL`).
    private static let colorSchemeGType: GType = {
        guard let settingsClass = g_type_class_ref(gtk_settings_get_type()) else { return 0 }
        defer { g_type_class_unref(settingsClass) }
        let objectClass = settingsClass.assumingMemoryBound(to: GObjectClass.self)
        guard let pspec = g_object_class_find_property(objectClass, colorSchemePropertyName)
        else { return 0 }
        return pspec.pointee.value_type
    }()

    private static var hasColorSchemeProperty: Bool { colorSchemeGType != 0 }

    private static var notifySignalName: String {
        hasColorSchemeProperty
            ? "notify::gtk-interface-color-scheme"
            : "notify::gtk-application-prefer-dark-theme"
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
            notifySignalName,
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
        ThemeWatcher.writeIsDark(object: object, dark: isDark)
    }
}

#endif
