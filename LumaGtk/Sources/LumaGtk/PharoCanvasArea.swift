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
    private let area: ShaderEffect
    private var themeToken: gulong = 0
    private var built: [Int: Built] = [:]

    private struct Built {
        var handle: Int32
        var vertexGLSL: String
        var fragmentGLSL: String
        var vertices: [Float]
        /// What the runs of values and pictures were stamped when they were
        /// last handed over, so a change to a uniform does not re-upload a
        /// texture that has not moved.
        var stamps: [UInt64] = []
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
        watchInput()
        reportScale()

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
            let stamps = drawable.buffers.map(\.stamp) + drawable.images.map(\.stamp)
            if record.stamps != stamps {
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
                record.stamps = stamps
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

    /// Reports what the pointer and keyboard are doing, for whoever drives the
    /// scene to read. Nothing is delivered into the image: a snippet asks.
    private func watchInput() {
        area.widget.canFocus = true
        area.widget.focusable = true

        let motion = EventControllerMotion()
        motion.onMotion { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.reportPointer(x: x, y: y, isInside: true) }
        }
        motion.onLeave { [weak self] _ in
            MainActor.assumeIsolated {
                self?.report { $0.isPointerInside = false }
            }
        }
        area.widget.install(controller: motion)

        let click = GestureClick()
        click.set(button: 0)
        click.onPressed { [weak self] gesture, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.area.widget.grabFocus()
                self.reportPointer(x: x, y: y, isInside: true)
                self.report { $0.buttons |= Self.mask(for: UInt32(gesture.currentButton)) }
            }
        }
        click.onReleased { [weak self] gesture, _, _, _ in
            MainActor.assumeIsolated {
                self?.report { $0.buttons &= ~Self.mask(for: UInt32(gesture.currentButton)) }
            }
        }
        area.widget.install(controller: click)

        let keys = EventControllerKey()
        keys.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                self?.report { $0.keysDown.insert(Self.code(for: UInt32(keyval))) }
            }
            return false
        }
        keys.onKeyReleased { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                self?.report { $0.keysDown.remove(Self.code(for: UInt32(keyval))) }
            }
        }
        area.widget.install(controller: keys)
    }

    /// Clip space, so what a snippet reads is in the coordinates it gave its
    /// vertices in.
    private func reportPointer(x: Double, y: Double, isInside: Bool) {
        let width = Double(area.widget.width)
        let height = Double(area.widget.height)
        guard width > 0, height > 0 else { return }

        report {
            $0.pointerX = Float(x / width * 2 - 1)
            $0.pointerY = Float(1 - y / height * 2)
            $0.isPointerInside = isInside
        }
    }

    private func reportScale() {
        CanvasRegistry.shared.reportScale(scene, Float(area.widget.scaleFactor))
    }

    private func report(_ change: (inout CanvasInput) -> Void) {
        CanvasRegistry.shared.reportInput(scene, change)
    }

    private static func mask(for button: UInt32) -> Int32 {
        switch button {
        case 3: return 1 << 1
        case 2: return 1 << 2
        default: return 1 << 0
        }
    }

    /// GDK's own keyvals, mapped onto what a scene is asked about: the named
    /// keys, and otherwise whatever character was typed.
    private static func code(for keyval: UInt32) -> Int32 {
        switch keyval {
        case 0xff51: return CanvasKey.left.rawValue
        case 0xff52: return CanvasKey.up.rawValue
        case 0xff53: return CanvasKey.right.rawValue
        case 0xff54: return CanvasKey.down.rawValue
        case 0xff0d, 0xff8d: return CanvasKey.enter.rawValue
        case 0xff1b: return CanvasKey.escape.rawValue
        default:
            let unicode = gdk_keyval_to_unicode(keyval)
            guard unicode != 0, let scalar = Unicode.Scalar(unicode) else { return 0 }
            return CanvasKey.code(for: Character(scalar))
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
