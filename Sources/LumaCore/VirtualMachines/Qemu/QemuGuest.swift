import Foundation

struct QemuGuest {
    let id: String
    let name: String
    let summary: String
    let iconName: String
    let operatingSystem: VirtualMachineOperatingSystem
    let emulator: String
    let machine: String
    let cpu: String?
    let vga: String
    let architecture: VirtualMachineArchitecture
    let agentFlavor: BareboneAgentFlavor?
    /// Where the machine maps PCI configuration space, which is how the agent finds the
    /// hostlink on a machine whose devices are not at addresses everyone agrees on.
    let ecam: UInt64?
    let boot: QemuBoot
    let pointer: QemuPointer
    let defaultMemory: Int

    static let all: [QemuGuest] = [
        QemuGuest(
            id: "qemu.win95",
            name: "Windows 9x",
            summary: "A Windows 95, 98 or Me disk image. Frida injects the win9x agent into its kernel.",
            iconName: "windows-9x",
            operatingSystem: .windows,
            emulator: "qemu-system-i386",
            machine: "pc,accel=tcg",
            cpu: "pentium3",
            vga: "cirrus",
            architecture: .x86,
            agentFlavor: .win9xX86,
            ecam: nil,
            boot: .diskImage(defaultInterface: .ide),
            pointer: .ps2,
            defaultMemory: 128
        ),
        QemuGuest(
            id: "qemu.winxp",
            name: "Windows XP",
            summary: "A 32-bit Windows XP disk image. Frida injects the winnt agent into its kernel.",
            iconName: "windows-nt",
            operatingSystem: .windows,
            emulator: "qemu-system-i386",
            machine: "pc,accel=tcg",
            cpu: "core2duo",
            vga: "std",
            architecture: .x86,
            agentFlavor: .winntX86,
            ecam: nil,
            boot: .diskImage(defaultInterface: .ide),
            pointer: .usbTablet,
            defaultMemory: 512
        ),
        QemuGuest(
            id: "qemu.winxp64",
            name: "Windows XP x64",
            summary: "A 64-bit Windows XP disk image. Frida injects the winnt agent into its kernel.",
            iconName: "windows-nt",
            operatingSystem: .windows,
            emulator: "qemu-system-x86_64",
            machine: "pc,accel=tcg",
            cpu: "core2duo",
            vga: "std",
            architecture: .x86_64,
            agentFlavor: .winntX86_64,
            ecam: nil,
            boot: .diskImage(defaultInterface: .ide),
            pointer: .usbTablet,
            defaultMemory: 1024
        ),
        QemuGuest(
            id: "qemu.linux-arm64",
            name: "Alpine Linux (arm64)",
            summary: """
                A kernel and its ramdisk, booted on QEMU's virt machine. Frida injects the linux \
                agent into the kernel, and from there into the processes it is asked to attach to.
                """,
            iconName: "linux",
            operatingSystem: .linux,
            emulator: "qemu-system-aarch64",
            machine: "virt",
            cpu: "max",
            vga: "",
            architecture: .arm64,
            agentFlavor: .linuxArm64,
            ecam: 0x40_1000_0000,
            boot: .linuxKernel,
            pointer: .usbTablet,
            defaultMemory: 2048
        ),
        QemuGuest(
            id: "qemu.linux-x86_64",
            name: "Linux kernel (x86-64)",
            summary: "A stock kernel with no root filesystem, for looking at bare memory.",
            iconName: "linux",
            operatingSystem: .linux,
            emulator: "qemu-system-x86_64",
            machine: "pc,accel=tcg",
            cpu: nil,
            vga: "std",
            architecture: .x86_64,
            agentFlavor: nil,
            ecam: nil,
            boot: .kernelImage,
            pointer: .usbTablet,
            defaultMemory: 256
        ),
        QemuGuest(
            id: "qemu.linux-x86",
            name: "Linux kernel (x86)",
            summary: "A stock kernel with no root filesystem, for looking at bare memory.",
            iconName: "linux",
            operatingSystem: .linux,
            emulator: "qemu-system-i386",
            machine: "pc,accel=tcg",
            cpu: nil,
            vga: "std",
            architecture: .x86,
            agentFlavor: nil,
            ecam: nil,
            boot: .kernelImage,
            pointer: .usbTablet,
            defaultMemory: 256
        ),
    ]

    static func named(_ id: String) -> QemuGuest? {
        all.first { $0.id == id }
    }

    var template: VirtualMachineTemplate {
        VirtualMachineTemplate(
            id: id,
            backendID: "qemu",
            name: name,
            summary: summary,
            iconName: iconName,
            operatingSystem: operatingSystem,
            architecture: architecture,
            agentFlavor: agentFlavor,
            parameters: boot.parameters + [
                VirtualMachineParameter(
                    id: QemuParameter.memory,
                    name: "Memory",
                    kind: .number(default: defaultMemory, min: 32, max: 16384, unit: "MB")
                )
            ]
        )
    }

    func arguments(
        for request: VirtualMachineLaunchRequest,
        gdbPort: UInt16,
        qmpPath: URL,
        agentQmpPath: URL,
        snapshotDisk: URL
    ) throws -> [String] {
        var arguments = ["-machine", machine, "-m", String(request.number(QemuParameter.memory) ?? defaultMemory)]

        if let cpu {
            arguments += ["-cpu", cpu]
        }

        arguments += try boot.arguments(for: request)
        if request.resumesFromReadySnapshot {
            arguments += ["-loadvm", QemuIdentifier.readySnapshot]
        }
        arguments += ["-drive", "file=\(snapshotDisk.path),format=qcow2,if=none,id=\(QemuIdentifier.snapshotDisk)"]
        arguments += pointer.arguments
        arguments += vga.isEmpty ? ["-device", "virtio-gpu-pci"] : ["-vga", vga]
        arguments += [
            "-serial", "file:\(request.storageDirectory.appendingPathComponent("serial.log").path)",
            "-chardev",
            "file,id=\(QemuIdentifier.agentLogChardev),path=\(request.storageDirectory.appendingPathComponent("agent.log").path)",
            "-device", "isa-debugcon,iobase=0xe9,chardev=\(QemuIdentifier.agentLogChardev)",
            "-device", "virtio-serial-pci,id=\(QemuIdentifier.hostlinkController)",
            "-nic", "none",
            "-display", "dbus,p2p=yes",
            "-monitor", "none",
            "-no-shutdown",
            "-qmp", "unix:\(qmpPath.path),server=on,wait=off",
            "-qmp", "unix:\(agentQmpPath.path),server=on,wait=off",
            "-chardev", "socket,id=\(QemuIdentifier.gdbChardev),host=127.0.0.1,port=\(gdbPort),server=on,wait=off",
            "-gdb", "chardev:\(QemuIdentifier.gdbChardev)",
        ]
        return arguments
    }
}

enum QemuPointer {
    case usbTablet
    case ps2

    var arguments: [String] {
        switch self {
        case .usbTablet:
            return ["-usb", "-device", "usb-tablet"]
        case .ps2:
            return []
        }
    }

    var isAbsolute: Bool {
        self == .usbTablet
    }
}

enum QemuBoot {
    case diskImage(defaultInterface: QemuDiskInterface)
    case kernelImage
    /// A kernel that boots into a userland of its own, and the map of its symbols, which is
    /// what the agent is given in place of the image itself.
    case linuxKernel

    var parameters: [VirtualMachineParameter] {
        switch self {
        case .diskImage(let defaultInterface):
            return [
                VirtualMachineParameter(
                    id: QemuParameter.diskImage,
                    name: "Disk image",
                    kind: .filePath(extensions: ["qcow2", "img", "vmdk", "vhd", "raw"])
                ),
                VirtualMachineParameter(
                    id: QemuParameter.diskFormat,
                    name: "Format",
                    kind: .choice(
                        options: [
                            VirtualMachineParameterOption(id: "qcow2", name: "qcow2"),
                            VirtualMachineParameterOption(id: "raw", name: "raw"),
                            VirtualMachineParameterOption(id: "vmdk", name: "VMDK"),
                        ],
                        default: "qcow2"
                    )
                ),
                VirtualMachineParameter(
                    id: QemuParameter.diskInterface,
                    name: "Disk interface",
                    kind: .choice(
                        options: [
                            VirtualMachineParameterOption(id: QemuDiskInterface.ide.rawValue, name: "IDE"),
                            VirtualMachineParameterOption(id: QemuDiskInterface.lsi.rawValue, name: "LSI SCSI"),
                        ],
                        default: defaultInterface.rawValue
                    )
                ),
            ]
        case .kernelImage:
            return [
                VirtualMachineParameter(
                    id: QemuParameter.kernelImage,
                    name: "Kernel image",
                    kind: .filePath(extensions: [])
                )
            ]
        case .linuxKernel:
            return [
                VirtualMachineParameter(
                    id: QemuParameter.kernelImage,
                    name: "Kernel image",
                    kind: .filePath(extensions: [])
                ),
                VirtualMachineParameter(
                    id: QemuParameter.ramdisk,
                    name: "Ramdisk",
                    kind: .filePath(extensions: ["img", "gz", "cpio"])
                ),
                VirtualMachineParameter(
                    id: QemuParameter.symbols,
                    name: "Symbols",
                    kind: .filePath(extensions: ["map"])
                ),
            ]
        }
    }

    func arguments(for request: VirtualMachineLaunchRequest) throws -> [String] {
        switch self {
        case .diskImage:
            guard let image = request.text(QemuParameter.diskImage), !image.isEmpty else {
                throw VirtualMachineError.launchFailed(reason: "No disk image was chosen")
            }
            let format = request.text(QemuParameter.diskFormat) ?? "qcow2"
            let drive = "file=\(image),format=\(format)"

            let interface = QemuDiskInterface(rawValue: request.text(QemuParameter.diskInterface) ?? "") ?? .ide
            switch interface {
            case .ide:
                return ["-drive", drive + ",if=ide"]
            case .lsi:
                return [
                    "-drive", drive + ",if=none,id=\(QemuIdentifier.guestDisk)",
                    "-device", "lsi53c895a,id=scsi0",
                    "-device", "scsi-hd,drive=\(QemuIdentifier.guestDisk),bus=scsi0.0",
                ]
            }
        case .kernelImage:
            guard let kernel = request.text(QemuParameter.kernelImage), !kernel.isEmpty else {
                throw VirtualMachineError.launchFailed(reason: "No kernel image was chosen")
            }
            return ["-kernel", kernel, "-append", "console=ttyS0 console=tty0 panic=0", "-no-reboot"]
        case .linuxKernel:
            guard let kernel = request.text(QemuParameter.kernelImage), !kernel.isEmpty else {
                throw VirtualMachineError.launchFailed(reason: "No kernel image was chosen")
            }
            guard let ramdisk = request.text(QemuParameter.ramdisk), !ramdisk.isEmpty else {
                throw VirtualMachineError.launchFailed(reason: "No ramdisk was chosen")
            }

            // The hostlink is a port of the same virtio device the kernel's own console driver
            // takes, and it takes it first.
            return [
                "-kernel", kernel,
                "-initrd", ramdisk,
                "-append", "console=ttyAMA0 initcall_blacklist=virtio_console_init",
                "-no-reboot",
            ]
        }
    }
}

enum QemuDiskInterface: String {
    case ide
    case lsi
}

enum QemuParameter {
    static let diskImage = "disk-image"
    static let diskFormat = "disk-format"
    static let diskInterface = "disk-interface"
    static let kernelImage = "kernel-image"
    static let ramdisk = "ramdisk"
    static let symbols = "symbols"
    static let memory = "memory"
}

enum QemuIdentifier {
    static let gdbChardev = "luma-gdb"
    static let agentLogChardev = "luma-agent-log"
    static let hostlinkController = "frida-vserial"
    /// QEMU names a controller's bus after the controller, and takes only the
    /// bus when a port is plugged into it.
    static let hostlinkBus = "\(hostlinkController).0"
    static let hostlinkPort = "hostlink.port"
    static let hostlinkChardev = "vserial0"
    static let guestDisk = "luma-disk"
    static let snapshotDisk = "luma-snapshot"
    static let displayFD = "luma-display"
    static let readySnapshot = "luma-ready"
}

