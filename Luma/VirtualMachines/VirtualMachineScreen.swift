import LumaCore
import SwiftUI

struct VirtualMachineScreen: View {
    let source: any VirtualMachineFrameSource

    @Binding var isPointerCaptured: Bool

    @FocusState private var isFocused: Bool
    @State private var isPointerInside = false
    @State private var showsReleaseHint = false

    var body: some View {
        GeometryReader { geometry in
            let frame = source.frame
            let placement = placement(of: frame, in: geometry.size)

            ZStack {
                Color.black

                if let frame, let image = image(of: frame, at: source.revision) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: placement.width, height: placement.height)
                        .position(x: placement.midX, y: placement.midY)
                }
            }
            .clipShape(Self.border)
            .overlay(Self.border.strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2))
            .overlay(pointer(frame: frame, placement: placement))
            .overlay(alignment: .bottom) { captureHint }
            .animation(.easeInOut(duration: 0.2), value: pointerHint)
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(phases: [.down, .up]) { press in
                send(press)
                return .handled
            }
            .onAppear { isFocused = true }
        }
    }

    private static let border = RoundedRectangle(cornerRadius: 6)

    @ViewBuilder
    private var captureHint: some View {
        if let hint = pointerHint {
            Text(hint)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
                .transition(.opacity)
        }
    }

    private var pointerHint: String? {
        guard !source.pointerIsAbsolute else { return nil }
        if showsReleaseHint {
            return "Hold Control-Option to release the pointer"
        }
        return (isPointerInside && !isPointerCaptured) ? "Click to drive the pointer" : nil
    }

    @ViewBuilder
    private func pointer(frame: VirtualMachineFrame?, placement: CGRect) -> some View {
        #if canImport(AppKit)
        VirtualMachinePointerCapture(
            placement: placement,
            guestSize: frame.map { CGSize(width: $0.width, height: $0.height) },
            isAbsolute: source.pointerIsAbsolute,
            send: { source.send($0) },
            captureChanged: { captured in
                isPointerCaptured = captured
                showsReleaseHint = captured
            },
            hoverChanged: { isPointerInside = $0 }
        )
        .task(id: showsReleaseHint) {
            guard showsReleaseHint else { return }
            try? await Task.sleep(for: .seconds(3))
            showsReleaseHint = false
        }
        #endif
    }

    private func send(_ press: KeyPress) {
        guard let code = code(for: press) else { return }
        source.send(press.phase == .down ? .keyDown(code: code) : .keyUp(code: code))
    }

    private func code(for press: KeyPress) -> UInt32? {
        if let key = VirtualMachineKey(press.key) {
            return VirtualMachineKeyboard.code(for: key)
        }
        guard let character = press.characters.first else { return nil }
        return VirtualMachineKeyboard.code(for: character)
    }

    private func placement(of frame: VirtualMachineFrame?, in size: CGSize) -> CGRect {
        guard let frame, frame.width > 0, frame.height > 0 else { return .zero }

        let scale = min(size.width / CGFloat(frame.width), size.height / CGFloat(frame.height))
        let width = CGFloat(frame.width) * scale
        let height = CGFloat(frame.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func image(of frame: VirtualMachineFrame, at revision: UInt64) -> CGImage? {
        let pixels = frame.withPixels { Data($0) }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }

        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

extension VirtualMachineKey {
    init?(_ equivalent: KeyEquivalent) {
        switch equivalent {
        case .escape: self = .escape
        case .delete: self = .backspace
        case .deleteForward: self = .delete
        case .tab: self = .tab
        case .return: self = .return
        case .space: self = .space
        case .upArrow: self = .upArrow
        case .downArrow: self = .downArrow
        case .leftArrow: self = .leftArrow
        case .rightArrow: self = .rightArrow
        case .home: self = .home
        case .end: self = .end
        case .pageUp: self = .pageUp
        case .pageDown: self = .pageDown
        default: return nil
        }
    }
}

extension VirtualMachineFrameSource {
    var aspectRatio: CGFloat {
        guard let frame, frame.height > 0 else { return 4 / 3 }
        return CGFloat(frame.width) / CGFloat(frame.height)
    }
}
