import CGtk
import CLuma
import Gtk
import LumaCore

/// A scene drawn inside an object's views, rather than off in a window. The
/// image holds the scene and changes it; this follows, rebuilding only what
/// differs so moving a drawable does not recompile its shaders.
@MainActor
final class PharoCanvasArea {
    let widget: Widget

    private let scene: Int
    private var area: UnsafeMutableRawPointer?
    private var themeToken: gulong = 0
    private var built: [Int: Built] = [:]

    private struct Built {
        var handle: Int32
        var vertexGLSL: String
        var fragmentGLSL: String
        var vertices: [Float]
    }

    init(scene: Int) {
        self.scene = scene

        let box = Box(orientation: .vertical, spacing: 0)
        box.hexpand = true
        box.vexpand = true
        widget = box

        guard let raw = luma_shader_effect_new(nil) else { return }
        area = raw
        applyAppearance(raw)
        themeToken = ThemeWatcher.subscribe(owner: self) { owner in
            if let raw = owner.area {
                owner.applyAppearance(raw)
            }
        }

        let surface = WidgetRef(raw: raw)
        surface.hexpand = true
        surface.vexpand = true
        box.append(child: surface)

        PharoCanvasScenes.register(self, for: scene)
        if let current = CanvasRegistry.shared.scene(scene) {
            apply(current)
        }
    }

    deinit {
        ThemeWatcher.unsubscribe(handlerID: themeToken)
    }

    func apply(_ scene: CanvasScene) {
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

/// Which areas are showing which scene, so a change reaches the view drawing
/// it wherever that view happens to be.
@MainActor
enum PharoCanvasScenes {
    private static var areas: [Int: [WeakArea]] = [:]

    private struct WeakArea {
        weak var area: PharoCanvasArea?
    }

    static func register(_ area: PharoCanvasArea, for scene: Int) {
        areas[scene, default: []].append(WeakArea(area: area))
    }

    static func apply(_ scene: CanvasScene, to handle: Int) {
        areas[handle] = areas[handle]?.filter { $0.area != nil }
        for entry in areas[handle] ?? [] {
            entry.area?.apply(scene)
        }
    }
}
