import Foundation

#if canImport(Virtualization)
import Virtualization

/// A Linux guest boots what it is handed -- a kernel, whatever ramdisk goes
/// with it, and a root filesystem if there is one -- so nothing is installed
/// and nothing is kept between boots.
@available(macOS 13, *)
struct VirtualizationLinuxImage {
    let kernel: URL
    let ramdisk: URL?
    let commandLine: String
    let disk: URL?

    init(request: VirtualMachineLaunchRequest) throws {
        guard let kernel = request.text(VirtualizationParameter.kernel), !kernel.isEmpty else {
            throw VirtualMachineError.launchFailed(reason: "No kernel was chosen")
        }
        self.kernel = URL(fileURLWithPath: kernel)

        let ramdisk = request.text(VirtualizationParameter.ramdisk) ?? ""
        self.ramdisk = ramdisk.isEmpty ? nil : URL(fileURLWithPath: ramdisk)

        let disk = request.text(VirtualizationParameter.disk) ?? ""
        self.disk = disk.isEmpty ? nil : URL(fileURLWithPath: disk)

        let commandLine = request.text(VirtualizationParameter.commandLine) ?? ""
        self.commandLine = commandLine.isEmpty ? VirtualizationLinuxImage.defaultCommandLine : commandLine
    }

    func makeConfiguration(memory: Int, processors: Int) throws -> VZVirtualMachineConfiguration {
        let bootLoader = VZLinuxBootLoader(kernelURL: kernel)
        bootLoader.initialRamdiskURL = ramdisk
        bootLoader.commandLine = commandLine

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = bootLoader
        configuration.cpuCount = processors
        configuration.memorySize = UInt64(memory) * 1024 * 1024

        let screen = VZVirtioGraphicsDeviceConfiguration()
        screen.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
        configuration.graphicsDevices = [screen]

        if let disk {
            configuration.storageDevices = [
                VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false))
            ]
        }

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]

        let console = VZVirtioConsoleDeviceConfiguration()
        let port = VZVirtioConsolePortConfiguration()
        port.isConsole = true
        console.ports[0] = port
        configuration.consoleDevices = [console]

        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        return configuration
    }

    /// The last console named is the one a shell lands on, so the screen is
    /// put last: a guest told only about the serial port draws nothing.
    private static let defaultCommandLine = "console=hvc0 console=tty0"
}

#endif
