export interface ProcessInfo {
    platform: Platform;
    arch: Architecture;
    pointerSize: number;
}

export function getProcessInfo(): ProcessInfo {
    return {
        platform: Process.platform,
        arch: Process.arch,
        pointerSize: Process.pointerSize,
    };
}
