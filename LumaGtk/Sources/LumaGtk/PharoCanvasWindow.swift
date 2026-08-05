import Adw
import CGtk
import CLuma
import Gtk
import LumaCore

/// A window showing one scene the image built. The image keeps the scene's
/// handle and changes it; this follows, rebuilding only what actually
/// differs, so moving a drawable does not recompile its shaders.
@MainActor
final class PharoCanvasWindow {
    private static var scenes: [Int: PharoCanvasWindow] = [:]
    private static var effect: PharoCanvasWindow?

    /// Teaches `LumaCanvas` in the image how to reach a window here.
    static func install(app: Adw.Application) {
        CanvasRegistry.onChange = { handle, scene in
            // A scene shown inside an object's views belongs there; only one
            // nobody is drawing gets a window of its own.
            PharoCanvasScenes.apply(scene, to: handle)
        }

        PharoCanvasHost.onShow = { shown in
            showEffect(shown, app: app)
        }
        PharoCanvasHost.onReport = { activity in
            effect?.report(activity)
        }
        PharoCanvasHost.onData = { values in
            effect?.feed(values)
        }
        PharoCanvasHost.onTransform = { values in
            effect?.transform(values)
        }
        PharoCanvasHost.onClose = {
            effect?.window.close()
            effect = nil
        }
    }

    private static func show(_ scene: CanvasScene, handle: Int, app: Adw.Application) {
        let existing = scenes[handle]
        let window = existing ?? PharoCanvasWindow(title: "Canvas", app: app)
        if existing == nil {
            scenes[handle] = window
            window.window.present()
        }
        window.apply(scene)
    }

    private static func showEffect(_ shown: CanvasEffect, app: Adw.Application) {
        effect?.window.close()
        let window = PharoCanvasWindow(title: "Canvas — \(shown.function)", app: app)
        effect = window
        window.adopt(shown)
        window.window.present()
    }

    let window: Adw.ApplicationWindow

    private var area: UnsafeMutableRawPointer?
    private var themeToken: gulong = 0
    /// What each drawable was last given, so an edit only touches what moved.
    private var built: [Int: Built] = [:]

    private struct Built {
        var handle: Int32
        var vertexGLSL: String
        var fragmentGLSL: String
        var vertices: [Float]
    }

    private init(title: String, app: Adw.Application) {
        window = Adw.ApplicationWindow(app: app)
        window.title = title
        window.setDefaultSize(width: 720, height: 420)

        let content = Box(orientation: .vertical, spacing: 0)
        content.append(child: Gtk.HeaderBar())

        if let raw = luma_shader_effect_new(nil) {
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

    private func apply(_ scene: CanvasScene) {
        guard let area else { return }

        for handle in scene.order {
            guard let drawable = scene.drawables[handle], !drawable.vertexGLSL.isEmpty else { continue }

            var record = built[handle] ?? Built(
                handle: luma_shader_effect_add_drawable(area),
                vertexGLSL: "", fragmentGLSL: "", vertices: [])

            if record.vertexGLSL != drawable.vertexGLSL || record.fragmentGLSL != drawable.fragmentGLSL {
                luma_shader_effect_drawable_set_program(
                    area, record.handle, drawable.vertexGLSL, drawable.fragmentGLSL)
                for attribute in drawable.geometry.attributes {
                    luma_shader_effect_drawable_add_attribute(
                        area, record.handle, attribute.name, Int32(attribute.components))
                }
                record.vertexGLSL = drawable.vertexGLSL
                record.fragmentGLSL = drawable.fragmentGLSL
                record.vertices = []
            }

            if record.vertices != drawable.geometry.vertices {
                var vertices = drawable.geometry.vertices
                vertices.withUnsafeMutableBufferPointer { buffer in
                    luma_shader_effect_drawable_set_vertices(
                        area, record.handle, buffer.baseAddress, Int32(buffer.count),
                        drawable.geometry.primitive.rawValue)
                }
                record.vertices = drawable.geometry.vertices
            }

            var transform = drawable.transform
            transform.withUnsafeMutableBufferPointer { buffer in
                luma_shader_effect_drawable_set_transform(area, record.handle, buffer.baseAddress)
            }
            luma_shader_effect_drawable_set_visible(area, record.handle, drawable.isVisible)

            built[handle] = record
        }

        for (handle, record) in built where scene.drawables[handle] == nil {
            luma_shader_effect_remove_drawable(area, record.handle)
            built[handle] = nil
        }
    }

    /// The older screen-filling path, where the image names one effect.
    private func adopt(_ shown: CanvasEffect) {
        guard let area else { return }

        let drawable = luma_shader_effect_add_drawable(area)
        if let geometry = shown.geometry, let vertexGLSL = shown.vertexGLSL {
            luma_shader_effect_drawable_set_program(area, drawable, vertexGLSL, shown.glsl)
            for attribute in geometry.attributes {
                luma_shader_effect_drawable_add_attribute(
                    area, drawable, attribute.name, Int32(attribute.components))
            }
            var vertices = geometry.vertices
            vertices.withUnsafeMutableBufferPointer { buffer in
                luma_shader_effect_drawable_set_vertices(
                    area, drawable, buffer.baseAddress, Int32(buffer.count),
                    geometry.primitive.rawValue)
            }
        }
    }

    private func feed(_ values: [Float]) {
        guard let area else { return }
        var storage = values
        storage.withUnsafeMutableBufferPointer { buffer in
            luma_shader_effect_set_data(area, buffer.baseAddress, Int32(buffer.count))
        }
    }

    private func transform(_ values: [Float]) {
        guard let area else { return }
        var storage = values
        storage.withUnsafeMutableBufferPointer { buffer in
            luma_shader_effect_set_transform(area, buffer.baseAddress)
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
