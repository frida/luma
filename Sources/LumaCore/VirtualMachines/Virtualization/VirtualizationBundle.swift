import Foundation

#if canImport(Virtualization)
import Virtualization

/// What a macOS guest keeps between boots: the disk it was installed on, the
/// hardware it believes it is, and the storage the firmware writes to.
@available(macOS 13, *)
struct VirtualizationBundle {
    let directory: URL

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: machineIdentifier.path)
    }

    var hasSavedState: Bool {
        FileManager.default.fileExists(atPath: savedState.path)
    }

    var savedState: URL {
        directory.appendingPathComponent("SavedState.vzvmsave")
    }

    var kernelImage: URL? {
        let image = directory.appendingPathComponent("kernelcache")
        return FileManager.default.fileExists(atPath: image.path) ? image : nil
    }

    /// A restore image carries the kernelcache the guest will boot, and that
    /// kernelcache carries the kernel's symbols -- every name the agent asks
    /// for, rather than a list the user has to write out.
    func keepKernelImage(from restoreImage: URL) throws {
        let listing = try run("/usr/bin/unzip", ["-Z1", restoreImage.path, "kernelcache.release.vma*"])
        guard let entry = listing.split(separator: "\n").map(String.init).first else {
            throw VirtualMachineError.launchFailed(reason: "That restore image carries no kernel for a virtual Mac")
        }

        _ = try run("/usr/bin/unzip", ["-o", "-j", restoreImage.path, entry, "-d", directory.path])

        let extracted = directory.appendingPathComponent((entry as NSString).lastPathComponent)
        guard extracted != kernelImageURL else { return }
        try? FileManager.default.removeItem(at: kernelImageURL)
        try FileManager.default.moveItem(at: extracted, to: kernelImageURL)
    }

    private var kernelImageURL: URL {
        directory.appendingPathComponent("kernelcache")
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func prepare(hardwareModel: VZMacHardwareModel, diskSizeInGigabytes: Int) throws {
        try hardwareModel.dataRepresentation.write(to: self.hardwareModel)

        let identifier = VZMacMachineIdentifier()
        try identifier.dataRepresentation.write(to: machineIdentifier)

        _ = try VZMacAuxiliaryStorage(creatingStorageAt: auxiliaryStorage, hardwareModel: hardwareModel)

        guard FileManager.default.createFile(atPath: disk.path, contents: nil) else {
            throw VirtualMachineError.launchFailed(reason: "Unable to make room for the guest's disk")
        }
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: UInt64(diskSizeInGigabytes) * 1024 * 1024 * 1024)
        try handle.close()
    }

    func makeConfiguration(memory: Int, processors: Int) throws -> VZVirtualMachineConfiguration {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = try readHardwareModel()
        platform.machineIdentifier = try readMachineIdentifier()
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliaryStorage)

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = processors
        configuration.memorySize = UInt64(memory) * 1024 * 1024

        let screen = VZMacGraphicsDeviceConfiguration()
        screen.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 2560, heightInPixels: 1600, pixelsPerInch: 220)]
        configuration.graphicsDevices = [screen]

        configuration.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false))
        ]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]

        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        return configuration
    }

    private func readHardwareModel() throws -> VZMacHardwareModel {
        guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: hardwareModel)) else {
            throw VirtualMachineError.launchFailed(reason: "The guest's hardware model is unreadable")
        }
        return model
    }

    private func readMachineIdentifier() throws -> VZMacMachineIdentifier {
        guard let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: machineIdentifier)) else {
            throw VirtualMachineError.launchFailed(reason: "The guest's identity is unreadable")
        }
        return identifier
    }

    private var disk: URL {
        directory.appendingPathComponent("Disk.img")
    }

    private var auxiliaryStorage: URL {
        directory.appendingPathComponent("AuxiliaryStorage")
    }

    private var hardwareModel: URL {
        directory.appendingPathComponent("HardwareModel")
    }

    private var machineIdentifier: URL {
        directory.appendingPathComponent("MachineIdentifier")
    }
}

#endif
