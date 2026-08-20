import LumaCore
import SwiftUI

#if canImport(Virtualization)
import Virtualization
#endif

/// Whichever way a machine offers its display: pixels the host draws, or a
/// layer the host adopts.
struct VirtualMachineDisplayView: View {
    let display: VirtualMachineDisplay
    var capturing: PointerCapturePolicy = .onClick
    var dismissal: String? = nil

    var body: some View {
        screen
    }

    @ViewBuilder
    private var screen: some View {
        switch display {
        case .frames(let source):
            VirtualMachineScreen(source: source, capturing: capturing, dismissal: dismissal)
                .aspectRatio(source.aspectRatio, contentMode: .fit)

        case .hostedWindow(let source):
            hosted(source)

        #if canImport(Virtualization)
        case .virtualizationGuest(let guest):
            VirtualizationScreen(guest: guest)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
        #endif
        }
    }

    @ViewBuilder
    private func hosted(_ source: any VirtualMachineWindowSource) -> some View {
        #if canImport(AppKit)
        VirtualMachineWindowPlacement(source: source)
            .aspectRatio(CGFloat(source.pixelWidth) / CGFloat(source.pixelHeight), contentMode: .fit)
        #endif
    }
}


#if canImport(Virtualization) && canImport(AppKit)
/// Virtualization.framework draws its own guest, and takes the keyboard and
/// pointer with it, so the host only has to give it somewhere to appear.
@available(macOS 13, *)
struct VirtualizationScreen: PlatformViewRepresentable {
    let guest: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.virtualMachine = guest
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = guest
    }
}
#endif
