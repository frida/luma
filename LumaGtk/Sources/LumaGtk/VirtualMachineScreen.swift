import CCairo
import Cairo
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class VirtualMachineScreen {
    let widget: Box

    private let source: any VirtualMachineFrameSource
    private let area: DrawingArea
    private var lastRevision: UInt64 = .max
    private var redrawTask: Task<Void, Never>?

    private var placement: (x: Double, y: Double, width: Double, height: Double) = (0, 0, 0, 0)

    init(source: any VirtualMachineFrameSource, interactive: Bool = true) {
        self.source = source

        widget = Box(orientation: .vertical, spacing: 0)
        area = DrawingArea()
        area.hexpand = true
        area.vexpand = true
        widget.append(child: area)

        area.setDrawFunc { [weak self] _, ctx, width, height in
            MainActor.assumeIsolated {
                self?.draw(ctx: ctx, width: Double(width), height: Double(height))
            }
        }

        if interactive {
            attachKeyboard()
            attachPointer()
        }

        redrawTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard let self else { return }
                guard self.source.revision != self.lastRevision else { continue }
                self.lastRevision = self.source.revision
                self.area.queueDraw()
            }
        }
    }

    deinit {
        redrawTask?.cancel()
    }

    private func draw(ctx: Cairo.ContextRef, width: Double, height: Double) {
        let raw = ctx.context_ptr

        cairo_set_source_rgb(raw, 0, 0, 0)
        cairo_rectangle(raw, 0, 0, width, height)
        cairo_fill(raw)

        guard let frame = source.frame, frame.width > 0, frame.height > 0 else {
            placement = (0, 0, 0, 0)
            return
        }

        let scale = min(width / Double(frame.width), height / Double(frame.height))
        let drawnWidth = Double(frame.width) * scale
        let drawnHeight = Double(frame.height) * scale
        let originX = ((width - drawnWidth) / 2).rounded()
        let originY = ((height - drawnHeight) / 2).rounded()
        placement = (originX, originY, drawnWidth, drawnHeight)

        frame.withPixels { pixels in
            guard let base = pixels.baseAddress else { return }
            let mutable = UnsafeMutableRawPointer(mutating: base)
                .assumingMemoryBound(to: UInt8.self)
            guard let surface = cairo_image_surface_create_for_data(
                mutable,
                Cairo.Format.argb32.value,
                Int32(frame.width), Int32(frame.height), Int32(frame.stride))
            else { return }
            defer { cairo_surface_destroy(surface) }

            cairo_save(raw)
            cairo_translate(raw, originX, originY)
            cairo_scale(raw, scale, scale)
            cairo_set_source_surface(raw, surface, 0, 0)
            if let pattern = cairo_get_source(raw) {
                cairo_pattern_set_filter(pattern, CAIRO_FILTER_NEAREST)
            }
            cairo_paint(raw)
            cairo_restore(raw)
        }
    }

    private func attachKeyboard() {
        area.focusable = true
        area.canFocus = true

        let keys = EventControllerKey()
        keys.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                guard let self, let code = Self.code(forKeyval: keyval) else { return false }
                self.source.send(.keyDown(code: code))
                return true
            }
        }
        keys.onKeyReleased { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                guard let self, let code = Self.code(forKeyval: keyval) else { return }
                self.source.send(.keyUp(code: code))
            }
        }
        area.install(controller: keys)
    }

    private func attachPointer() {
        let motion = EventControllerMotion()
        motion.onMotion { [weak self] _, x, y in
            MainActor.assumeIsolated {
                self?.sendPointer(at: x, y: y)
            }
        }
        area.install(controller: motion)

        let buttons: [(Int, VirtualMachinePointerButton)] = [
            (1, .left), (2, .middle), (3, .right),
        ]
        for (gtkButton, guestButton) in buttons {
            let click = GestureClick()
            click.set(button: gtkButton)
            click.onPressed { [weak self] _, _, x, y in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    _ = self.area.grabFocus()
                    self.sendPointer(at: x, y: y)
                    self.source.send(.pointerButtonDown(button: guestButton))
                }
            }
            click.onReleased { [weak self] _, _, _, _ in
                MainActor.assumeIsolated {
                    self?.source.send(.pointerButtonUp(button: guestButton))
                }
            }
            area.install(controller: click)
        }

        let scroll = EventControllerScroll(flags: .bothAxes)
        scroll.onScroll { [weak self] _, dx, dy in
            MainActor.assumeIsolated {
                self?.source.send(.scrolled(deltaX: dx, deltaY: dy))
                return true
            }
        }
        area.install(controller: scroll)
    }

    private func sendPointer(at x: Double, y: Double) {
        guard placement.width > 0, placement.height > 0, let frame = source.frame else { return }

        let guestX = (x - placement.x) / placement.width * Double(frame.width)
        let guestY = (y - placement.y) / placement.height * Double(frame.height)
        guard guestX >= 0, guestY >= 0,
            guestX < Double(frame.width), guestY < Double(frame.height)
        else { return }

        source.send(.pointerMoved(x: guestX, y: guestY))
    }

    private static func code(forKeyval keyval: UInt) -> UInt32? {
        if let key = named(keyval) {
            return VirtualMachineKeyboard.code(for: key)
        }
        guard keyval >= 0x20, keyval <= 0x7e, let scalar = Unicode.Scalar(UInt32(keyval)) else {
            return nil
        }
        return VirtualMachineKeyboard.code(for: Character(scalar))
    }

    private static func named(_ keyval: UInt) -> VirtualMachineKey? {
        switch keyval {
        case 0xff1b: return .escape
        case 0xff08: return .backspace
        case 0xff09: return .tab
        case 0xff0d, 0xff8d: return .return
        case 0x0020: return .space
        case 0xffe1, 0xffe2: return .leftShift
        case 0xffe3, 0xffe4: return .leftControl
        case 0xffe9, 0xffea: return .leftAlt
        case 0xffe5: return .capsLock
        case 0xff52: return .upArrow
        case 0xff54: return .downArrow
        case 0xff51: return .leftArrow
        case 0xff53: return .rightArrow
        case 0xffff: return .delete
        case 0xff50: return .home
        case 0xff57: return .end
        case 0xff55: return .pageUp
        case 0xff56: return .pageDown
        case 0xffbe...0xffc9: return .function(UInt8(keyval - 0xffbe + 1))
        default: return nil
        }
    }
}
