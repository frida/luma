#if canImport(Virtualization)
import Foundation
import ObjectiveC
import Virtualization

/// The parts of Virtualization.framework that boot a research guest are not
/// declared in its headers, so they are reached through the runtime.
enum VZPrivateAPI {
    static func researchHardwareModel(boardID: UInt32, isa: Int64) -> VZMacHardwareModel? {
        guard let descriptor = make("_VZMacHardwareModelDescriptor") else { return nil }

        descriptor.setValue(NSNumber(value: platformVersion), forKey: "platformVersion")
        descriptor.setValue(NSNumber(value: boardID), forKey: "boardID")
        descriptor.setValue(NSNumber(value: isa), forKey: "ISA")

        let model = send(VZMacHardwareModel.self, "_hardwareModelWithDescriptor:", descriptor)
        return model as? VZMacHardwareModel
    }

    static func setROM(_ url: URL, on bootLoader: VZMacOSBootLoader) {
        _ = send(bootLoader, "_setROMURL:", url as NSURL)
    }

    static func setNVRAMVariable(_ name: String, to value: String, in storage: VZMacAuxiliaryStorage) {
        typealias Setter = @convention(c) (AnyObject, Selector, NSData, NSString, UnsafeMutableRawPointer?) -> Bool
        let selector = NSSelectorFromString("_setDataValue:forNVRAMVariableNamed:error:")
        guard let method = storage.method(for: selector) else { return }

        let setter = unsafeBitCast(method, to: Setter.self)
        _ = setter(storage, selector, Data(value.utf8) as NSData, name as NSString, nil)
    }

    static func makeDebugStub(port: Int) -> NSObject? {
        typealias Initialiser = @convention(c) (AnyObject, Selector, Int) -> AnyObject?
        guard let stub = allocate("_VZGDBDebugStubConfiguration") else { return nil }

        let selector = NSSelectorFromString("initWithPort:")
        guard let method = stub.method(for: selector) else { return nil }

        let initialise = unsafeBitCast(method, to: Initialiser.self)
        return initialise(stub, selector, port) as? NSObject
    }

    static func setDebugStub(_ stub: NSObject, on configuration: VZVirtualMachineConfiguration) {
        _ = send(configuration, "_setDebugStub:", stub)
    }

    static func makeSEPCoprocessor(storage: URL, rom: URL?, debugStub: NSObject?) -> NSObject? {
        guard let coprocessor = allocate("_VZSEPCoprocessorConfiguration") else { return nil }

        let selector = NSSelectorFromString("initWithStorageURL:")
        guard let initialised = send(coprocessor, selector, storage as NSURL) as? NSObject else { return nil }

        if let rom {
            _ = send(initialised, "setRomBinaryURL:", rom as NSURL)
        }
        if let debugStub {
            _ = send(initialised, "setDebugStub:", debugStub)
        }
        return initialised
    }

    static func setCoprocessors(_ coprocessors: [NSObject], on configuration: VZVirtualMachineConfiguration) {
        _ = send(configuration, "_setCoprocessors:", coprocessors as NSArray)
    }

    static func makeSerialPort() -> VZSerialPortConfiguration? {
        make("_VZPL011SerialPortConfiguration") as? VZSerialPortConfiguration
    }

    static func makeMultiTouchDevice() -> NSObject? {
        make("_VZUSBTouchScreenConfiguration")
    }

    static func setMultiTouchDevices(_ devices: [NSObject], on configuration: VZVirtualMachineConfiguration) {
        _ = send(configuration, "_setMultiTouchDevices:", devices as NSArray)
    }

    /// The platform version a research guest asks for, which the framework
    /// only grants to a caller carrying the private entitlements.
    private static let platformVersion: UInt32 = 3

    private static func make(_ className: String) -> NSObject? {
        guard let type = NSClassFromString(className) as? NSObject.Type else { return nil }
        return type.init()
    }

    private static func allocate(_ className: String) -> NSObject? {
        guard let type = NSClassFromString(className) as? NSObject.Type else { return nil }
        return type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
    }

    private static func send(_ target: AnyObject, _ selector: String, _ argument: AnyObject? = nil) -> AnyObject? {
        send(target, NSSelectorFromString(selector), argument)
    }

    private static func send(_ target: AnyObject, _ selector: Selector, _ argument: AnyObject?) -> AnyObject? {
        guard target.responds(to: selector) else { return nil }
        guard let argument else {
            return target.perform(selector)?.takeUnretainedValue()
        }
        return target.perform(selector, with: argument)?.takeUnretainedValue()
    }
}
#endif
