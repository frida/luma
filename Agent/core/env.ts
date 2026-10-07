export interface ProcessInfo {
    platform: Platform;
    arch: Architecture;
    pointerSize: number;
    mainModule: ModuleInfo | null;
    identity: string;
}

export interface ModuleInfo {
    name: string;
    path: string;
    base: string;
    size: number;
}

export function getProcessInfo(): ProcessInfo {
    return {
        platform: Process.platform,
        arch: Process.arch,
        pointerSize: Process.pointerSize,
        mainModule: lookupMainModule(),
        identity: computeProcessIdentity(),
    };
}

function lookupMainModule(): ModuleInfo | null {
    let main: Module;
    try {
        main = Process.mainModule;
    } catch (_) {
        return null;
    }
    return {
        name: main.name,
        path: main.path,
        base: main.base.toString(),
        size: main.size,
    };
}

function computeProcessIdentity(): string {
    const source = osSpecificIdentitySource() ?? fallbackIdentitySource();
    const sum = new Checksum("sha256");
    sum.update(source);
    return sum.getString().slice(0, 16);
}

function osSpecificIdentitySource(): string | null {
    try {
        switch (Process.platform) {
            case "linux": return linuxIdentitySource();
            case "darwin": return darwinIdentitySource();
            case "windows": return windowsIdentitySource();
            default: return null;
        }
    } catch (_) {
        return null;
    }
}

function fallbackIdentitySource(): string {
    return `mainbase=${lookupMainModule()?.base ?? "?"};pid=${Process.id}`;
}

function linuxIdentitySource(): string {
    const bootID = File.readAllText("/proc/sys/kernel/random/boot_id").trim();
    const stat = File.readAllText("/proc/self/stat");
    const afterComm = stat.slice(stat.lastIndexOf(")") + 1).trim().split(/\s+/);
    const startTimeJiffies = afterComm[19];
    return `boot=${bootID};start=${startTimeJiffies};pid=${Process.id}`;
}

function darwinIdentitySource(): string {
    const sysctl: SysctlFunction = new NativeFunction(
        Module.getGlobalExportByName("sysctl"),
        "int",
        ["pointer", "uint", "pointer", "pointer", "pointer", "size_t"]
    );
    return `boot=${darwinBootTime(sysctl)};start=${darwinProcStartTime(sysctl)};pid=${Process.id}`;
}

function darwinBootTime(sysctl: SysctlFunction): string {
    const mib = Memory.alloc(8);
    mib.writeU32(CTL_KERN); mib.add(4).writeU32(KERN_BOOTTIME);
    return readSysctlTimeval(sysctl, mib, 2);
}

function darwinProcStartTime(sysctl: SysctlFunction): string {
    const mib = Memory.alloc(16);
    mib.writeU32(CTL_KERN);
    mib.add(4).writeU32(KERN_PROC);
    mib.add(8).writeU32(KERN_PROC_PID);
    mib.add(12).writeU32(Process.id);
    return readSysctlTimeval(sysctl, mib, 4);
}

function readSysctlTimeval(sysctl: SysctlFunction, mib: NativePointer, mibCount: number): string {
    const buf = Memory.alloc(16);
    const len = Memory.alloc(Process.pointerSize);
    len.writeULong(16);
    sysctl(mib, mibCount, buf, len, NULL, 0);
    const sec = buf.readS64();
    const usec = buf.add(8).readS32();
    return `${sec}.${usec}`;
}

type SysctlFunction = NativeFunction<number, [NativePointer, number, NativePointer, NativePointer, NativePointer, number]>;

function windowsIdentitySource(): string {
    const getProcessTimes = new NativeFunction(
        Module.getGlobalExportByName("GetProcessTimes"),
        "int32",
        ["pointer", "pointer", "pointer", "pointer", "pointer"]
    );
    const buf = Memory.alloc(32);
    getProcessTimes(WINDOWS_CURRENT_PROCESS, buf, buf.add(8), buf.add(16), buf.add(24));
    const low = buf.readU32();
    const high = buf.add(4).readU32();
    return `create=${high}.${low};pid=${Process.id}`;
}

const WINDOWS_CURRENT_PROCESS = ptr(-1);

const CTL_KERN = 1;
const KERN_PROC = 14;
const KERN_BOOTTIME = 21;
const KERN_PROC_PID = 1;
const NULL = ptr(0);

