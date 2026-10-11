import { Buffer } from "buffer";
import fs, { Stats } from "frida-fs";

export interface FilesystemRoots {
    root: string;
    home: string | null;
    cwd: string | null;
    tmp: string | null;
}

export function getFilesystemRoots(): FilesystemRoots {
    return {
        root: (Process.platform === "windows") ? "C:\\" : "/",
        home: existingDirectory(() => Process.getHomeDir()),
        cwd: existingDirectory(() => Process.getCurrentDir()),
        tmp: existingDirectory(() => Process.getTmpDir()),
    };
}

function existingDirectory(read: () => string): string | null {
    try {
        const path = read();
        return fs.statSync(path).isDirectory() ? path : null;
    } catch (e) {
        return null;
    }
}

export interface DirectoryListing {
    path: string;
    entries: FileEntry[];
}

export interface FileEntry {
    name: string;
    kind: FileKind;
    target: LinkTarget | null;
    size: number;
    mtime: number;
    permissions: string;
    owner: string;
    group: string;
}

export interface LinkTarget {
    path: string;
    kind: FileKind | null;
}

export type FileKind = "file" | "directory" | "symlink" | "character-device" | "block-device" | "fifo" | "socket";

export function listDirectory(path: string): DirectoryListing {
    const entries: FileEntry[] = [];
    for (const name of fs.readdirSync(path)) {
        const entryPath = joinPath(path, name);
        let stats: Stats;
        try {
            stats = fs.lstatSync(entryPath);
        } catch (e) {
            continue;
        }
        entries.push(entryFromStats(entryPath, name, stats));
    }
    return { path, entries };
}

function joinPath(directory: string, name: string): string {
    const separator = directory.includes("\\") && !directory.includes("/") ? "\\" : "/";
    return directory.endsWith(separator) ? directory + name : directory + separator + name;
}

function entryFromStats(path: string, name: string, stats: Stats): FileEntry {
    const kind = kindFromMode(stats.mode);
    return {
        name,
        kind,
        target: (kind === "symlink") ? linkTarget(path) : null,
        size: stats.size,
        mtime: stats.mtimeMs,
        permissions: permissionsFromMode(stats.mode),
        owner: resolveUserID(stats.uid),
        group: resolveGroupID(stats.gid),
    };
}

function linkTarget(path: string): LinkTarget {
    const targetPath = fs.readlinkSync(path);
    let kind: FileKind | null;
    try {
        kind = kindFromMode(fs.statSync(path).mode);
    } catch (e) {
        kind = null;
    }
    return { path: targetPath, kind };
}

const { S_IFMT, S_IFREG, S_IFDIR, S_IFCHR, S_IFBLK, S_IFIFO, S_IFLNK, S_IFSOCK } = fs.constants;

function kindFromMode(mode: number): FileKind {
    switch (mode & S_IFMT) {
        case S_IFREG: return "file";
        case S_IFDIR: return "directory";
        case S_IFLNK: return "symlink";
        case S_IFCHR: return "character-device";
        case S_IFBLK: return "block-device";
        case S_IFIFO: return "fifo";
        case S_IFSOCK: return "socket";
    }
    throw new Error(`Invalid mode: 0x${mode.toString(16)}`);
}

function permissionsFromMode(mode: number): string {
    let access = "";
    for (let shift = 8; shift >= 0; shift -= 3) {
        access += ((mode >>> shift) & 1) !== 0 ? "r" : "-";
        access += ((mode >>> (shift - 1)) & 1) !== 0 ? "w" : "-";
        access += ((mode >>> (shift - 2)) & 1) !== 0 ? "x" : "-";
    }
    return access;
}

export interface TreeEntry {
    path: string;
    components: string[];
    kind: "file" | "directory";
    size: number;
}

export function walkTree(root: string): TreeEntry[] {
    const stats = fs.statSync(root);
    const components = [baseName(root)];
    if (stats.isFile()) {
        return [{ path: root, components, kind: "file", size: stats.size }];
    }
    if (!stats.isDirectory()) {
        throw new Error(`${root} is neither a file nor a directory`);
    }
    const entries: TreeEntry[] = [{ path: root, components, kind: "directory", size: 0 }];
    walkDirectory(root, components, entries);
    return entries;
}

function walkDirectory(directory: string, components: string[], entries: TreeEntry[]): void {
    for (const name of fs.readdirSync(directory)) {
        const path = joinPath(directory, name);
        const childComponents = [...components, name];
        const stats = fs.lstatSync(path);
        if (stats.isDirectory()) {
            entries.push({ path, components: childComponents, kind: "directory", size: 0 });
            walkDirectory(path, childComponents, entries);
        } else if (stats.isFile()) {
            entries.push({ path, components: childComponents, kind: "file", size: stats.size });
        } else if (stats.isSymbolicLink()) {
            const target = statOrNull(path);
            if (target !== null && target.isFile()) {
                entries.push({ path, components: childComponents, kind: "file", size: target.size });
            }
        }
    }
}

function statOrNull(path: string): Stats | null {
    try {
        return fs.statSync(path);
    } catch (e) {
        return null;
    }
}

function baseName(path: string): string {
    const trimmed = path.replace(/[\\/]+$/, "");
    const cut = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
    return trimmed.substring(cut + 1);
}

export function makeDirectory(path: string): void {
    fs.mkdirSync(path, { recursive: true });
}

const activePulls = new Map<number, () => void>();

export function pullFile(path: string, id: number): number {
    const size = fs.statSync(path).size;
    const reader = fs.createReadStream(path);
    activePulls.set(id, () => reader.destroy());
    reader.on("data", (chunk: Buffer) => {
        send({ type: "fs:chunk", id }, chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength) as ArrayBuffer);
    });
    reader.on("end", () => {
        activePulls.delete(id);
        send({ type: "fs:end", id });
    });
    reader.on("error", (error: Error) => {
        activePulls.delete(id);
        send({ type: "fs:error", id, error: error.message });
    });
    return size;
}

export function cancelPull(id: number): void {
    const cancel = activePulls.get(id);
    activePulls.delete(id);
    cancel?.();
}

type PushMessage =
    | { action: "write" }
    | { action: "end" }
    | { action: "cancel" };

export function pushFile(path: string, id: number): void {
    const writer = fs.createWriteStream(path);
    writer.on("finish", () => {
        send({ type: "fs:end", id });
    });
    writer.on("error", (error: Error) => {
        send({ type: "fs:error", id, error: error.message });
    });
    const messageType = `fs:push:${id}`;
    const onMessage = (message: PushMessage, data: ArrayBuffer | null) => {
        switch (message.action) {
            case "write":
                writer.write(Buffer.from(data!), () => {
                    send({ type: "fs:ack", id });
                });
                break;
            case "end":
                writer.end();
                return;
            case "cancel":
                writer.once("close", () => discardPartialFile(path));
                writer.destroy();
                return;
        }
        recv(messageType, onMessage);
    };
    recv(messageType, onMessage);
}

function discardPartialFile(path: string): void {
    try {
        fs.unlinkSync(path);
    } catch (e) {
    }
}

const ERANGE = 34;
const { pointerSize } = Process;
const cachedUsers = new Map<number, string>();
const cachedGroups = new Map<number, string>();
type LookupFunction = SystemFunction<number, [number, NativePointerValue, NativePointerValue, number, NativePointerValue]>;
let getpwuidR: LookupFunction | null = null;
let getgrgidR: LookupFunction | null = null;

function resolveUserID(uid: number): string {
    return resolveID(uid, cachedUsers, () => {
        if (getpwuidR === null) {
            getpwuidR = makeLookupFunction("getpwuid_r");
        }
        return getpwuidR;
    });
}

function resolveGroupID(gid: number): string {
    return resolveID(gid, cachedGroups, () => {
        if (getgrgidR === null) {
            getgrgidR = makeLookupFunction("getgrgid_r");
        }
        return getgrgidR;
    });
}

function makeLookupFunction(name: string): LookupFunction {
    return new SystemFunction(Module.getGlobalExportByName(name), "int", ["uint", "pointer", "pointer", "size_t", "pointer"]);
}

function resolveID(id: number, cache: Map<number, string>, lookupFunction: () => LookupFunction): string {
    const cached = cache.get(id);
    if (cached !== undefined) {
        return cached;
    }
    const name = (Process.platform === "windows") ? id.toString() : lookupName(id, lookupFunction());
    cache.set(id, name);
    return name;
}

function lookupName(id: number, lookup: LookupFunction): string {
    const recordCapacity = 128;
    let bufferCapacity = 1024;
    while (true) {
        const record = Memory.alloc(recordCapacity + bufferCapacity + pointerSize);
        const buffer = record.add(recordCapacity);
        const result = buffer.add(bufferCapacity);
        const r = lookup(id, record, buffer, bufferCapacity, result) as UnixSystemFunctionResult<number>;
        if (r.value === 0) {
            const entry = result.readPointer();
            return entry.isNull() ? id.toString() : entry.readPointer().readUtf8String()!;
        }
        if (r.errno !== ERANGE) {
            return id.toString();
        }
        bufferCapacity *= 2;
    }
}
