import CCairo
import CLuma
import Cairo
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class VirtualMachineScreen {
    let widget: Box

    private let source: any VirtualMachineFrameSource
    private let sizing: Sizing
    private let aspect: AspectFrame
    private let area: DrawingArea
    private let hintLabel: Label
    private var lastRevision: UInt64 = .max
    private var redrawTask: Task<Void, Never>?

    private var placement: (x: Double, y: Double, width: Double, height: Double) = (0, 0, 0, 0)

    enum Sizing {
        case fitsContainer
        case guestResolution
    }

    private enum PointerMode {
        case free
        case captured(anchor: Anchor)
    }

    private struct Anchor {
        let local: (x: Double, y: Double)
        let global: (x: Double, y: Double)?
    }

    private var pointer: PointerMode = .free
    private var lastPointerPosition: (x: Double, y: Double) = (0, 0)
    private var isPointerInside = false
    private var isFocused = false

    init(
        source: any VirtualMachineFrameSource,
        interactive: Bool = true,
        sizing: Sizing = .fitsContainer
    ) {
        self.source = source
        self.sizing = sizing

        widget = Box(orientation: .vertical, spacing: 0)

        area = DrawingArea()
        area.hexpand = true

        hintLabel = Label(str: "")
        hintLabel.add(cssClass: "osd")
        hintLabel.add(cssClass: "caption")
        hintLabel.halign = .center
        hintLabel.valign = .end
        hintLabel.marginBottom = 8
        hintLabel.canTarget = false
        hintLabel.visible = false

        let overlay = Overlay()
        overlay.set(child: area)
        overlay.addOverlay(widget: hintLabel)
        overlay.hexpand = true

        aspect = AspectFrame(xalign: 0.5, yalign: 0.5, ratio: 4.0 / 3.0, obeyChild: false)
        aspect.hexpand = true
        aspect.set(child: overlay)
        widget.append(child: aspect)

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
                self.matchAspectToFrame()
                self.area.queueDraw()
            }
        }
    }

    deinit {
        redrawTask?.cancel()
    }

    private func matchAspectToFrame() {
        guard let frame = source.frame, frame.width > 0, frame.height > 0 else { return }
        aspect.ratio = CFloat(Double(frame.width) / Double(frame.height))

        guard case .guestResolution = sizing else { return }
        let shrinkage = min(1, Double(Self.widestGuestResolution) / Double(frame.width))
        area.setSizeRequest(
            width: Int(Double(frame.width) * shrinkage),
            height: Int(Double(frame.height) * shrinkage))
    }

    private static var widestGuestResolution: Int { 960 }

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
            let surfaceFormat: Cairo.Format
            switch frame.format {
            case .bgra8888: surfaceFormat = .argb32
            case .bgrx8888: surfaceFormat = .rgb24
            }
            guard let surface = cairo_image_surface_create_for_data(
                mutable,
                surfaceFormat.value,
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
        keys.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                guard let self else { return false }
                if Self.isReleaseChord(keyval: keyval, state: state) {
                    self.releasePointer()
                }
                if let key = Self.named(keyval) {
                    self.source.send(.keyDown(code: VirtualMachineKeyboard.code(for: key)))
                    return true
                }
                guard let stroke = Self.stroke(forKeyval: keyval) else { return false }
                let shift = VirtualMachineKeyboard.code(for: .leftShift)
                if stroke.shifted { self.source.send(.keyDown(code: shift)) }
                self.source.send(.keyDown(code: stroke.code))
                self.source.send(.keyUp(code: stroke.code))
                if stroke.shifted { self.source.send(.keyUp(code: shift)) }
                return true
            }
        }
        keys.onKeyReleased { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                guard let self, let key = Self.named(keyval) else { return }
                self.source.send(.keyUp(code: VirtualMachineKeyboard.code(for: key)))
            }
        }
        area.install(controller: keys)

        let focus = EventControllerFocus()
        focus.onEnter { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isFocused = true
                self?.refreshHint()
            }
        }
        focus.onLeave { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isFocused = false
                self.releasePointer()
                self.refreshHint()
            }
        }
        area.install(controller: focus)

        let focusClick = GestureClick()
        focusClick.set(button: 0)
        focusClick.propagationPhase = .capture
        focusClick.onPressed { [weak self] _, _, _, _ in
            MainActor.assumeIsolated { _ = self?.area.grabFocus() }
        }
        area.install(controller: focusClick)
    }

    private func attachPointer() {
        let motion = EventControllerMotion()
        motion.onEnter { [weak self] _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPointerInside = true
                self.refreshHint()
                self.sendPointer(at: x, y: y)
            }
        }
        motion.onMotion { [weak self] _, x, y in
            MainActor.assumeIsolated {
                self?.sendPointer(at: x, y: y)
            }
        }
        motion.onLeave { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPointerInside = false
                self.refreshHint()
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
                    if guestButton == .left, !self.source.pointerIsAbsolute,
                        case .free = self.pointer
                    {
                        self.capturePointer(at: x, y: y)
                        return
                    }
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

    private func capturePointer(at x: Double, y: Double) {
        var globalX = 0.0
        var globalY = 0.0
        let global = luma_pointer_location(&globalX, &globalY) ? (globalX, globalY) : nil
        pointer = .captured(anchor: Anchor(local: (x, y), global: global))
        lastPointerPosition = (x, y)

        if let ptr = area.widget_ptr.map(UnsafeMutableRawPointer.init) {
            luma_widget_set_cursor_name(ptr, "none")
        }
        refreshHint()
    }

    private func releasePointer() {
        guard case .captured = pointer else { return }
        pointer = .free

        if let ptr = area.widget_ptr.map(UnsafeMutableRawPointer.init) {
            luma_widget_set_cursor_name(ptr, nil)
        }
        refreshHint()
    }

    private func sendPointer(at x: Double, y: Double) {
        if source.pointerIsAbsolute {
            sendAbsolutePointer(at: x, y: y)
        } else {
            sendRelativePointer(at: x, y: y)
        }
    }

    private func sendAbsolutePointer(at x: Double, y: Double) {
        guard placement.width > 0, placement.height > 0, let frame = source.frame else { return }

        let guestX = (x - placement.x) / placement.width * Double(frame.width)
        let guestY = (y - placement.y) / placement.height * Double(frame.height)
        guard guestX >= 0, guestY >= 0,
            guestX < Double(frame.width), guestY < Double(frame.height)
        else { return }

        source.send(.pointerMoved(x: guestX, y: guestY))
    }

    private func sendRelativePointer(at x: Double, y: Double) {
        guard case .captured(let anchor) = pointer else { return }

        let dx = x - lastPointerPosition.x
        let dy = y - lastPointerPosition.y
        guard dx != 0 || dy != 0 else { return }

        if placement.width > 0, placement.height > 0, let frame = source.frame {
            source.send(
                .pointerMovedBy(
                    dx: dx * Double(frame.width) / placement.width,
                    dy: dy * Double(frame.height) / placement.height))
        }

        if let global = anchor.global {
            luma_pointer_place(global.x, global.y)
            lastPointerPosition = anchor.local
        } else {
            lastPointerPosition = (x, y)
        }
    }

    private func refreshHint() {
        guard let text = hintText else {
            hintLabel.visible = false
            return
        }
        hintLabel.label = text
        hintLabel.visible = true
    }

    private var hintText: String? {
        if case .captured = pointer { return "Ctrl+Alt releases the pointer" }
        guard isPointerInside else { return nil }
        if !isFocused { return "Click to send keys and clicks" }
        return source.pointerIsAbsolute ? nil : "Click to drive the pointer"
    }

    private static func isReleaseChord(keyval: UInt, state: Gdk.ModifierType) -> Bool {
        let controls: Set<UInt> = [0xffe3, 0xffe4]
        let alts: Set<UInt> = [0xffe9, 0xffea]
        return (controls.contains(keyval) && state.contains(.altMask))
            || (alts.contains(keyval) && state.contains(.controlMask))
    }

    private static func stroke(forKeyval keyval: UInt) -> VirtualMachineKeyStroke? {
        guard keyval >= 0x20, keyval <= 0x7e, let scalar = Unicode.Scalar(UInt32(keyval)) else {
            return nil
        }
        return VirtualMachineKeyboard.stroke(for: Character(scalar))
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
