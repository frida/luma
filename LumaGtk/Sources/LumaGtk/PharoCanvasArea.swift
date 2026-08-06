import CGtk
import CLuma
import Gtk
import LumaCore
import LumaGL

/// A scene drawn inside an object's views, rather than off in a window. The
/// image holds the scene and changes it; this follows, rebuilding only what
/// differs so moving a drawable does not recompile its shaders.
@MainActor
final class PharoCanvasArea {
    let widget: Widget

    private let scene: Int
    private let area: ShaderEffect
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
        area = ShaderEffect()

        let box = Box(orientation: .vertical, spacing: 0)
        box.hexpand = true
        box.vexpand = true
        widget = box

        applyAppearance()
        themeToken = ThemeWatcher.subscribe(owner: self) { owner in
            owner.applyAppearance()
        }

        area.widget.hexpand = true
        area.widget.vexpand = true
        box.append(child: area.widget)

        PharoCanvasScenes.register(self, for: scene)
        if let current = CanvasRegistry.shared.scene(scene) {
            apply(current)
        }
    }

    deinit {
        ThemeWatcher.unsubscribe(handlerID: themeToken)
    }

    func apply(_ scene: CanvasScene) {
        for handle in scene.order {
            guard let drawable = scene.drawables[handle], !drawable.vertexGLSL.isEmpty else { continue }

            var record = built[handle] ?? Built(
                handle: area.addDrawable(), vertexGLSL: "", fragmentGLSL: "", vertices: [])

            if record.vertexGLSL != drawable.vertexGLSL || record.fragmentGLSL != drawable.fragmentGLSL {
                area.setProgram(
                    record.handle, vertex: drawable.vertexGLSL, fragment: drawable.fragmentGLSL)
                for attribute in drawable.geometry.attributes {
                    area.addAttribute(
                        record.handle, name: attribute.name, components: attribute.components)
                }
                record.vertexGLSL = drawable.vertexGLSL
                record.fragmentGLSL = drawable.fragmentGLSL
                record.vertices = []
            }

            if record.vertices != drawable.geometry.vertices {
                area.setVertices(
                    record.handle, drawable.geometry.vertices,
                    primitive: drawable.geometry.primitive)
                record.vertices = drawable.geometry.vertices
            }

            area.setTransform(record.handle, drawable.transform)
            for uniform in drawable.uniforms {
                area.setUniform(record.handle, name: uniform.name, values: uniform.values)
            }
            for sheet in drawable.buffers {
                area.setBuffer(
                    record.handle, name: sheet.name, values: sheet.padded(),
                    width: sheet.width, height: sheet.height)
            }
            for picture in drawable.images {
                area.setImage(
                    record.handle, name: picture.name, pixels: picture.pixels,
                    width: picture.width, height: picture.height)
            }
            for driver in drawable.drivers {
                area.drive(
                    record.handle, name: driver.name, kind: driver.kind,
                    from: driver.from, to: driver.to, seconds: driver.seconds)
            }
            area.setVisible(record.handle, drawable.isVisible)

            built[handle] = record
        }

        for (handle, record) in built where scene.drawables[handle] == nil {
            area.removeDrawable(record.handle)
            built[handle] = nil
        }
    }

    private func applyAppearance() {
        let dark = ThemeWatcher.currentAppearance() == .dark
        area.setScheme(dark ? 0 : 1)
        if dark {
            area.setClearColor(red: 0.075, green: 0.050, blue: 0.065)
        } else {
            area.setClearColor(red: 0.994, green: 0.991, blue: 0.986)
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

    private static var listening = false

    static func register(_ area: PharoCanvasArea, for scene: Int) {
        listenOnce()
        areas[scene, default: []].append(WeakArea(area: area))
    }

    private static func listenOnce() {
        guard !listening else { return }
        listening = true
        CanvasRegistry.onChange = { handle, scene in
            apply(scene, to: handle)
        }
    }

    static func apply(_ scene: CanvasScene, to handle: Int) {
        areas[handle] = areas[handle]?.filter { $0.area != nil }
        for entry in areas[handle] ?? [] {
            entry.area?.apply(scene)
        }
    }
}
