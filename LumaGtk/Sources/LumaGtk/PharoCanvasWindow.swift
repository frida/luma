import Adw
import CGtk
import CLuma
import Gtk
import LumaCore

/// A window holding one shader effect, opened by the image so a snippet can
/// picture what it is working on. The image names an effect the build carries
/// and then feeds it; the drawing itself stays in the host.
@MainActor
final class PharoCanvasWindow {
    private static var shared: PharoCanvasWindow?

    /// Teaches `LumaCanvas` in the image how to reach a window here.
    static func install(app: Adw.Application) {
        PharoCanvasHost.onShow = { effect in
            show(effect, app: app)
        }
        PharoCanvasHost.onReport = { activity in
            shared?.report(activity)
        }
        PharoCanvasHost.onData = { values in
            shared?.feed(values)
        }
        PharoCanvasHost.onClose = {
            shared?.window.close()
            shared = nil
        }
    }

    private static func show(_ effect: CanvasEffect, app: Adw.Application) {
        if let existing = shared, existing.effect == effect {
            existing.window.present()
            return
        }
        shared?.window.close()
        shared = PharoCanvasWindow(effect: effect, app: app)
        shared?.window.present()
    }

    let window: Adw.ApplicationWindow

    private let effect: CanvasEffect
    private var area: UnsafeMutableRawPointer?
    private var themeToken: gulong = 0

    private init(effect: CanvasEffect, app: Adw.Application) {
        self.effect = effect
        window = Adw.ApplicationWindow(app: app)
        window.title = "Canvas — \(effect.function)"
        window.setDefaultSize(width: 720, height: 420)

        let content = Box(orientation: .vertical, spacing: 0)
        content.append(child: Gtk.HeaderBar())

        if let raw = luma_shader_effect_new(effect.glsl) {
            area = raw
            applyAppearance(raw)
            themeToken = ThemeWatcher.subscribe(owner: self) { owner in
                if let raw = owner.area {
                    owner.applyAppearance(raw)
                }
            }
            let widget = WidgetRef(raw: raw)
            widget.hexpand = true
            widget.vexpand = true
            content.append(child: widget)
        }

        window.set(content: content)
    }

    deinit {
        ThemeWatcher.unsubscribe(handlerID: themeToken)
    }

    private func feed(_ values: [Float]) {
        guard let area else { return }
        var storage = values
        storage.withUnsafeMutableBufferPointer { buffer in
            luma_shader_effect_set_data(area, buffer.baseAddress, Int32(buffer.count))
        }
    }

    private func report(_ activity: Float) {
        guard let area else { return }
        luma_shader_effect_report_activity(area, activity)
    }

    private func applyAppearance(_ raw: UnsafeMutableRawPointer) {
        let dark = ThemeWatcher.currentAppearance() == .dark
        luma_shader_effect_set_scheme(raw, dark ? 0.0 : 1.0)
        if dark {
            luma_shader_effect_set_clear_color(raw, 0.075, 0.050, 0.065)
        } else {
            luma_shader_effect_set_clear_color(raw, 0.994, 0.991, 0.986)
        }
    }
}
