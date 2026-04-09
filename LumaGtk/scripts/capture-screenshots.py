#!/usr/bin/env python3
"""Capture screenshots of LumaGtk views using Frida + headless Mutter.

Usage:
    # Under headless mutter (make screenshots handles this):
    python3 scripts/capture-screenshots.py <pid> <output-dir>
"""

import frida
import os
import struct
import sys
import time
import zlib

AGENT = r"""
const pinned = [];

const glib = find('libglib-2.0.so');
const gobject = find('libgobject-2.0.so');
const gtk = find('libgtk-4.so');

const g_idle_add = fn(glib, 'g_idle_add', 'uint', ['pointer', 'pointer']);
const g_object_unref = fn(gobject, 'g_object_unref', 'void', ['pointer']);
const g_type_check_instance_is_a = fn(gobject, 'g_type_check_instance_is_a', 'int', ['pointer', 'uint64']);
const g_type_from_name = fn(gobject, 'g_type_from_name', 'uint64', ['pointer']);
const g_application_get_default = fn(gtk, 'g_application_get_default', 'pointer', []);
const gdk_display_get_default = fn(gtk, 'gdk_display_get_default', 'pointer', []);
const gdk_surface_queue_render = fn(gtk, 'gdk_surface_queue_render', 'void', ['pointer']);
const gdk_texture_get_width = fn(gtk, 'gdk_texture_get_width', 'int', ['pointer']);
const gdk_texture_get_height = fn(gtk, 'gdk_texture_get_height', 'int', ['pointer']);
const gdk_texture_download = fn(gtk, 'gdk_texture_download', 'void', ['pointer', 'pointer', 'uint64']);
const gtk_application_get_active_window = fn(gtk, 'gtk_application_get_active_window', 'pointer', ['pointer']);
const gtk_native_get_surface = fn(gtk, 'gtk_native_get_surface', 'pointer', ['pointer']);
const gtk_widget_queue_draw = fn(gtk, 'gtk_widget_queue_draw', 'void', ['pointer']);
const gtk_widget_get_width = fn(gtk, 'gtk_widget_get_width', 'int', ['pointer']);
const gtk_widget_get_height = fn(gtk, 'gtk_widget_get_height', 'int', ['pointer']);
const gtk_widget_get_first_child = fn(gtk, 'gtk_widget_get_first_child', 'pointer', ['pointer']);
const gtk_widget_get_next_sibling = fn(gtk, 'gtk_widget_get_next_sibling', 'pointer', ['pointer']);
const gtk_list_box_select_row = fn(gtk, 'gtk_list_box_select_row', 'void', ['pointer', 'pointer']);
const gtk_list_box_get_row_at_index = fn(gtk, 'gtk_list_box_get_row_at_index', 'pointer', ['pointer', 'int']);
const gtk_label_get_text = fn(gtk, 'gtk_label_get_text', 'pointer', ['pointer']);
const gsk_renderer_render_texture = fn(gtk, 'gsk_renderer_render_texture', 'pointer', ['pointer', 'pointer', 'pointer']);
const gsk_renderer_realize_for_display = fn(gtk, 'gsk_renderer_realize_for_display', 'int', ['pointer', 'pointer', 'pointer']);
const gsk_renderer_unrealize = fn(gtk, 'gsk_renderer_unrealize', 'void', ['pointer']);
const gsk_cairo_renderer_new = fn(gtk, 'gsk_cairo_renderer_new', 'pointer', []);
const gsk_render_node_ref = fn(gtk, 'gsk_render_node_ref', 'pointer', ['pointer']);
const gsk_render_node_unref = fn(gtk, 'gsk_render_node_unref', 'void', ['pointer']);

const GTK_TYPE_LIST_BOX = g_type_from_name(Memory.allocUtf8String('GtkListBox'));
const GTK_TYPE_LABEL = g_type_from_name(Memory.allocUtf8String('GtkLabel'));

function find(prefix) {
    const m = Process.enumerateModules().find(m => m.name.startsWith(prefix));
    if (!m) throw new Error('Module not found: ' + prefix);
    return m;
}

function fn(mod, name, ret, args) {
    return new NativeFunction(mod.getExportByName(name), ret, args);
}

function scheduleOnMainThread(callback) {
    return new Promise((resolve, reject) => {
        const idle = new NativeCallback(() => {
            pinned.splice(pinned.indexOf(idle), 1);
            try { resolve(callback()); } catch (e) { reject(e); }
            return 0;
        }, 'int', ['pointer']);
        pinned.push(idle);
        g_idle_add(idle, NULL);
    });
}

function getWindow() {
    return gtk_application_get_active_window(g_application_get_default());
}

function firstLabel(widget) {
    if (g_type_check_instance_is_a(widget, GTK_TYPE_LABEL)) return widget;
    for (let child = gtk_widget_get_first_child(widget);
         !child.isNull();
         child = gtk_widget_get_next_sibling(child)) {
        const found = firstLabel(child);
        if (found !== null) return found;
    }
    return null;
}

function labelText(row) {
    const lbl = firstLabel(row);
    if (lbl === null) return '';
    const t = gtk_label_get_text(lbl);
    return t.isNull() ? '' : t.readUtf8String();
}

function allListBoxes(root) {
    const out = [];
    const stack = [root];
    while (stack.length > 0) {
        const widget = stack.pop();
        if (g_type_check_instance_is_a(widget, GTK_TYPE_LIST_BOX)) out.push(widget);
        for (let child = gtk_widget_get_first_child(widget);
             !child.isNull();
             child = gtk_widget_get_next_sibling(child)) {
            stack.push(child);
        }
    }
    return out;
}

let captureResolve = null;
let capturePendingNode = null;

Interceptor.attach(gtk.getExportByName('gsk_renderer_render'), {
    onEnter(args) {
        if (captureResolve !== null) {
            capturePendingNode = args[1];
            gsk_render_node_ref(capturePendingNode);
        }
    },
    onLeave() {
        if (capturePendingNode === null || captureResolve === null) return;

        const node = capturePendingNode;
        capturePendingNode = null;

        const cairo = gsk_cairo_renderer_new();
        gsk_renderer_realize_for_display(cairo, gdk_display_get_default(), NULL);
        const texture = gsk_renderer_render_texture(cairo, node, NULL);
        gsk_render_node_unref(node);
        gsk_renderer_unrealize(cairo);
        g_object_unref(cairo);

        if (texture.isNull()) {
            captureResolve(null);
            captureResolve = null;
            return;
        }

        const w = gdk_texture_get_width(texture);
        const h = gdk_texture_get_height(texture);
        const stride = w * 4;
        const buf = Memory.alloc(stride * h);
        gdk_texture_download(texture, buf, stride);
        g_object_unref(texture);

        captureResolve(buf.readByteArray(stride * h));
        captureResolve = null;
    }
});

rpc.exports = {
    getWindowSize() {
        return scheduleOnMainThread(() => {
            const win = getWindow();
            return [gtk_widget_get_width(win), gtk_widget_get_height(win)];
        });
    },

    captureScreenshot() {
        return new Promise(resolve => {
            captureResolve = resolve;
            const idle = new NativeCallback(() => {
                pinned.splice(pinned.indexOf(idle), 1);
                const win = getWindow();
                gtk_widget_queue_draw(win);
                gdk_surface_queue_render(gtk_native_get_surface(win));
                return 0;
            }, 'int', ['pointer']);
            pinned.push(idle);
            g_idle_add(idle, NULL);
            setTimeout(() => {
                if (captureResolve !== null) {
                    captureResolve(null);
                    captureResolve = null;
                }
            }, 5000);
        });
    },

    listSidebar() {
        return scheduleOnMainThread(() => {
            const items = [];
            for (const lb of allListBoxes(getWindow())) {
                for (let i = 0; ; i++) {
                    const row = gtk_list_box_get_row_at_index(lb, i);
                    if (row.isNull()) break;
                    items.push({ lb: lb.toString(), index: i, label: labelText(row) });
                }
            }
            return items;
        });
    },

    selectItem(lbAddr, index) {
        return scheduleOnMainThread(() => {
            const lb = ptr(lbAddr);
            const row = gtk_list_box_get_row_at_index(lb, index);
            if (row.isNull()) return false;
            gtk_list_box_select_row(lb, row);
            return true;
        });
    },
};
"""


def write_png(width, height, rgba_data):
    def chunk(ctype, data):
        c = ctype + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    raw = b""
    stride = width * 4
    for y in range(height):
        raw += b"\x00" + rgba_data[y * stride:(y + 1) * stride]
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def main():
    pid = int(sys.argv[1])
    outdir = sys.argv[2] if len(sys.argv) > 2 else "screenshots"
    os.makedirs(outdir, exist_ok=True)

    local = [d for d in frida.get_device_manager().enumerate_devices() if d.type == "local"][0]
    session = local.attach(pid)
    script = session.create_script(AGENT)

    def on_message(msg, data):
        if msg.get("type") == "error":
            print(f"  agent error: {msg.get('description', msg)}", flush=True)

    script.on("message", on_message)
    script.load()
    time.sleep(1)

    w, h = script.exports_sync.get_window_size()
    print(f"Window: {w}x{h}", flush=True)

    def capture(name):
        path = os.path.join(outdir, f"{name}.png")
        rgba = script.exports_sync.capture_screenshot()
        if rgba is None:
            print(f"  {name}: FAILED (timeout)", flush=True)
            return
        png = write_png(w, h, rgba)
        with open(path, "wb") as f:
            f.write(png)
        print(f"  {name}: {len(png)} bytes", flush=True)

    capture("notebook")

    # Poll sidebar until sessions appear
    items = []
    for _ in range(20):
        items = script.exports_sync.list_sidebar()
        if len(items) > 1:
            break
        time.sleep(0.5)

    print(f"Sidebar: {[i['label'] for i in items]}", flush=True)

    seen = {"notebook"}
    for item in items:
        label = item.get("label", "")
        if not label:
            continue
        slug = "".join(c if c.isascii() and c.isalnum() else "-" for c in label).strip("-").lower()
        slug = "-".join(s for s in slug.split("-") if s)
        if not slug:
            continue
        base = slug
        n = 1
        while slug in seen:
            n += 1
            slug = f"{base}-{n}"
        seen.add(slug)
        script.exports_sync.select_item(item["lb"], item["index"])
        # Extra wait for views with async content (e.g. Monaco editor)
        time.sleep(2)
        capture(slug)

    session.detach()
    print("Done.", flush=True)


if __name__ == "__main__":
    main()
