#!/usr/bin/env python3
"""Capture screenshots of Luma (macOS/SwiftUI) views using Frida + Accessibility.

Usage:
    python3 scripts/capture-screenshots.py <pid-or-name> <output-dir>

The agent navigates the sidebar via NSAccessibility, captures
each view with CGWindowListCreateImage (in-process, no TCC
needed for your own window), and sends raw RGBA back to Python.
"""

import frida
import os
import struct
import sys
import time
import zlib

AGENT = r"""
const pinned = [];

const AXUIElement = ObjCObject;

rpc.exports = {
    getWindowSize() {
        return withMainThread(() => {
            const win = getKeyWindow();
            const frame = win.frame();
            return [frame[2], frame[3]];
        });
    },

    captureScreenshot() {
        return withMainThread(() => {
            const win = getKeyWindow();
            const wid = win.windowNumber();
            const bounds = CGRectNull();
            const opts = 1 << 3; // kCGWindowListOptionIncludingWindow
            const imageOpts = 1; // kCGWindowImageBestResolution

            const cgImage = CGWindowListCreateImage(bounds, opts, wid, imageOpts);
            if (cgImage.isNull()) return null;

            const w = CGImageGetWidth(cgImage);
            const h = CGImageGetHeight(cgImage);
            const bitsPerComponent = 8;
            const bytesPerRow = w * 4;
            const total = bytesPerRow * h;

            const cs = CGColorSpaceCreateDeviceRGB();
            const ctx = CGBitmapContextCreate(NULL, w, h, bitsPerComponent, bytesPerRow, cs,
                1 /* kCGImageAlphaPremultipliedLast */ | (1 << 13) /* kCGBitmapByteOrder32Big */);
            CGContextDrawImage(ctx, [0, 0, w, h], cgImage);
            const data = CGBitmapContextGetData(ctx);
            const buf = data.readByteArray(total);
            CGContextRelease(ctx);
            CGColorSpaceRelease(cs);
            CGImageRelease(cgImage);

            return { width: w, height: h, rgba: buf };
        });
    },

    listSidebar() {
        return withMainThread(() => {
            const win = getKeyWindow();
            const axWin = axElement(win);
            const rows = findSidebarRows(axWin);
            return rows.map((r, i) => ({
                index: i,
                label: axTitle(r) || axDescription(r) || `row-${i}`,
            }));
        });
    },

    selectItem(index) {
        return withMainThread(() => {
            const win = getKeyWindow();
            const axWin = axElement(win);
            const rows = findSidebarRows(axWin);
            if (index >= rows.length) return false;
            const row = rows[index];
            axPerformAction(row, 'AXPress');
            return true;
        });
    },
};

function getKeyWindow() {
    const app = ObjC.classes.NSApplication.sharedApplication();
    const win = app.keyWindow();
    if (win.isNull()) {
        const windows = app.orderedWindows();
        if (windows.count() === 0) throw new Error('No windows');
        return windows.objectAtIndex_(0);
    }
    return win;
}

function axElement(nsObj) {
    return nsObj;
}

function findSidebarRows(axWin) {
    const rows = [];
    walkAccessibility(axWin, (el) => {
        const role = axRole(el);
        if (role === 'AXRow' || role === 'AXCell') {
            const parent = axParent(el);
            if (parent !== null) {
                const parentRole = axRole(parent);
                if (parentRole === 'AXOutlineRow' || parentRole === 'AXList'
                    || parentRole === 'AXOutline' || parentRole === 'AXTable') {
                    rows.push(el);
                    return false;
                }
            }
            const subrole = axSubrole(el);
            if (subrole === 'AXOutlineRow') {
                rows.push(el);
                return false;
            }
        }
        if (role === 'AXOutlineRow') {
            rows.push(el);
            return false;
        }
        return true;
    }, 0, 6);
    return rows;
}

function walkAccessibility(el, visitor, depth, maxDepth) {
    if (depth > maxDepth) return;
    const shouldDescend = visitor(el);
    if (!shouldDescend) return;

    const children = axChildren(el);
    if (children === null) return;

    for (let i = 0; i < children.length; i++) {
        walkAccessibility(children[i], visitor, depth + 1, maxDepth);
    }
}

function axRole(el) {
    try {
        const sel = ObjC.selector('accessibilityRole');
        if (el.respondsToSelector_(sel)) {
            const v = el.accessibilityRole();
            return v ? v.toString() : null;
        }
    } catch {}
    return null;
}

function axSubrole(el) {
    try {
        const sel = ObjC.selector('accessibilitySubrole');
        if (el.respondsToSelector_(sel)) {
            const v = el.accessibilitySubrole();
            return v ? v.toString() : null;
        }
    } catch {}
    return null;
}

function axTitle(el) {
    try {
        const sel = ObjC.selector('accessibilityTitle');
        if (el.respondsToSelector_(sel)) {
            const v = el.accessibilityTitle();
            return v ? v.toString() : null;
        }
    } catch {}
    return null;
}

function axDescription(el) {
    try {
        const sel = ObjC.selector('accessibilityLabel');
        if (el.respondsToSelector_(sel)) {
            const v = el.accessibilityLabel();
            return v ? v.toString() : null;
        }
    } catch {}
    return null;
}

function axParent(el) {
    try {
        const sel = ObjC.selector('accessibilityParent');
        if (el.respondsToSelector_(sel)) {
            const v = el.accessibilityParent();
            return v && !v.isNull() ? v : null;
        }
    } catch {}
    return null;
}

function axChildren(el) {
    try {
        const sel = ObjC.selector('accessibilityChildren');
        if (el.respondsToSelector_(sel)) {
            const arr = el.accessibilityChildren();
            if (arr === null || arr.isNull()) return null;
            const count = arr.count();
            const result = [];
            for (let i = 0; i < count; i++) {
                result.push(arr.objectAtIndex_(i));
            }
            return result;
        }
    } catch {}
    return null;
}

function axPerformAction(el, action) {
    try {
        const sel = ObjC.selector('accessibilityPerformPress');
        if (el.respondsToSelector_(sel)) {
            el.accessibilityPerformPress();
            return;
        }
    } catch {}
    try {
        if (el.respondsToSelector_(ObjC.selector('setAccessibilityFocused:'))) {
            el.setAccessibilityFocused_(true);
        }
    } catch {}
}

function withMainThread(callback) {
    if (ObjC.classes.NSThread.isMainThread()) {
        return callback();
    }
    return new Promise((resolve, reject) => {
        ObjC.schedule(ObjC.mainQueue, () => {
            try { resolve(callback()); } catch (e) { reject(e); }
        });
    });
}

const CG = Process.getModuleByName('CoreGraphics');
const CGWindowListCreateImage = new NativeFunction(
    CG.getExportByName('CGWindowListCreateImage'),
    'pointer', [['double', 'double', 'double', 'double'], 'uint32', 'uint32', 'uint32']);
const CGImageGetWidth = new NativeFunction(
    CG.getExportByName('CGImageGetWidth'), 'uint64', ['pointer']);
const CGImageGetHeight = new NativeFunction(
    CG.getExportByName('CGImageGetHeight'), 'uint64', ['pointer']);
const CGImageRelease = new NativeFunction(
    CG.getExportByName('CGImageRelease'), 'void', ['pointer']);
const CGColorSpaceCreateDeviceRGB = new NativeFunction(
    CG.getExportByName('CGColorSpaceCreateDeviceRGB'), 'pointer', []);
const CGColorSpaceRelease = new NativeFunction(
    CG.getExportByName('CGColorSpaceRelease'), 'void', ['pointer']);
const CGBitmapContextCreate = new NativeFunction(
    CG.getExportByName('CGBitmapContextCreate'),
    'pointer', ['pointer', 'uint64', 'uint64', 'uint64', 'uint64', 'pointer', 'uint32']);
const CGBitmapContextGetData = new NativeFunction(
    CG.getExportByName('CGBitmapContextGetData'), 'pointer', ['pointer']);
const CGContextDrawImage = new NativeFunction(
    CG.getExportByName('CGContextDrawImage'),
    'void', ['pointer', ['double', 'double', 'double', 'double'], 'pointer']);
const CGContextRelease = new NativeFunction(
    CG.getExportByName('CGContextRelease'), 'void', ['pointer']);

function CGRectNull() { return [0, 0, 0, 0]; }
"""


def main():
    target = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else "screenshots"
    os.makedirs(outdir, exist_ok=True)

    local = [d for d in frida.get_device_manager().enumerate_devices() if d.type == "local"][0]

    try:
        pid = int(target)
        session = local.attach(pid)
    except ValueError:
        session = local.attach(target)

    script = session.create_script(AGENT)
    script.on("message", on_message)
    script.load()
    time.sleep(2)

    w, h = script.exports_sync.get_window_size()
    print(f"Window: {w}x{h}", flush=True)

    capture(script, outdir, "notebook")

    items = poll_sidebar(script)
    print(f"Sidebar: {[i['label'] for i in items]}", flush=True)

    seen = {"notebook"}
    for item in items:
        slug = slugify(item.get("label", ""))
        if not slug:
            continue
        base = slug
        n = 1
        while slug in seen:
            n += 1
            slug = f"{base}-{n}"
        seen.add(slug)
        script.exports_sync.select_item(item["index"])
        time.sleep(2)
        capture(script, outdir, slug)

    session.detach()
    print("Done.", flush=True)


def capture(script, outdir, name):
    path = os.path.join(outdir, f"{name}.png")
    result = script.exports_sync.capture_screenshot()
    if result is None:
        print(f"  {name}: FAILED", flush=True)
        return
    w = result["width"]
    h = result["height"]
    rgba = result["rgba"]
    png = encode_png(w, h, rgba)
    with open(path, "wb") as f:
        f.write(png)
    print(f"  {name}: {w}x{h}, {len(png)} bytes", flush=True)


def poll_sidebar(script):
    items = []
    for _ in range(20):
        items = script.exports_sync.list_sidebar()
        if len(items) > 1:
            return items
        time.sleep(0.5)
    return items


def slugify(label):
    slug = "".join(c if c.isascii() and c.isalnum() else "-" for c in label)
    return "-".join(s for s in slug.strip("-").lower().split("-") if s)


def on_message(msg, data):
    if msg.get("type") == "error":
        print(f"  agent error: {msg.get('description', msg)}", flush=True)


def encode_png(width, height, rgba_data):
    stride = width * 4
    raw = b""
    for y in range(height):
        raw += b"\x00" + rgba_data[y * stride:(y + 1) * stride]
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return sig + png_chunk(b"IHDR", ihdr) + png_chunk(b"IDAT", zlib.compress(raw)) + png_chunk(b"IEND", b"")


def png_chunk(ctype, data):
    c = ctype + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)


if __name__ == "__main__":
    main()
