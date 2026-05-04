const pinned = [];

let latestMonacoText = null;

Interceptor.attach(Module.getGlobalExportByName('luma_monaco_view_evaluate'), {
    onEnter(args) {
        const script = args[1].readUtf8String();
        const match = setTextScriptRegex.exec(script);
        if (match !== null)
            latestMonacoText = base64DecodeUtf8(match[1]);
    }
});

const setTextScriptRegex = /editor\.setText\(atob\('([^']*)'\)\)/;

function base64DecodeUtf8(input) {
    const bytes = [];
    let buffer = 0;
    let bits = 0;
    for (const ch of input) {
        if (ch === '=') break;
        buffer = (buffer << 6) | base64Alphabet.indexOf(ch);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            bytes.push((buffer >> bits) & 0xff);
        }
    }
    return String.fromCharCode(...bytes);
}

const base64Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

const glib = findModule('libglib-2.0');
const gobject = findModule('libgobject-2.0');
const gio = findModule('libgio-2.0');
const gtk = findModule('libgtk-4');

const GLib = {
    idleAdd: nativeFn(glib, 'g_idle_add', 'uint', ['pointer', 'pointer']),
};

function gListToArray(list) {
    const out = [];
    let node = list;
    while (!node.isNull()) {
        out.push(node.readPointer());
        node = node.add(Process.pointerSize).readPointer();
    }
    return out;
}

function appWindows() {
    const app = Application.getDefault();
    if (app.isNull())
        return [];
    return gListToArray(GtkApplication.getWindows(app));
}

const GObject = {
    unref: nativeFn(gobject, 'g_object_unref', 'void', ['pointer']),
    typeCheckInstanceIsA: nativeFn(gobject, 'g_type_check_instance_is_a', 'int', ['pointer', 'uint64']),
    typeFromName: nativeFn(gobject, 'g_type_from_name', 'uint64', ['pointer']),
    typeName: nativeFn(gobject, 'g_type_name', 'pointer', ['uint64']),
};

const Gio = {
    fileNewForUri: nativeFn(gio, 'g_file_new_for_uri', 'pointer', ['pointer']),
    applicationOpen: nativeFn(gio, 'g_application_open', 'void', ['pointer', 'pointer', 'int', 'pointer']),
};

const Application = {
    getDefault: nativeFn(gtk, 'g_application_get_default', 'pointer', []),
};

const GdkDisplay = {
    getDefault: nativeFn(gtk, 'gdk_display_get_default', 'pointer', []),
};

const GdkSurface = {
    queueRender: nativeFn(gtk, 'gdk_surface_queue_render', 'void', ['pointer']),
};

const GdkTexture = {
    getWidth: nativeFn(gtk, 'gdk_texture_get_width', 'int', ['pointer']),
    getHeight: nativeFn(gtk, 'gdk_texture_get_height', 'int', ['pointer']),
    download: nativeFn(gtk, 'gdk_texture_download', 'void', ['pointer', 'pointer', 'uint64']),
};

const GtkApplication = {
    getActiveWindow: nativeFn(gtk, 'gtk_application_get_active_window', 'pointer', ['pointer']),
    getWindows: nativeFn(gtk, 'gtk_application_get_windows', 'pointer', ['pointer']),
};

const Native = {
    getSurface: nativeFn(gtk, 'gtk_native_get_surface', 'pointer', ['pointer']),
};

const Widget = {
    queueDraw: nativeFn(gtk, 'gtk_widget_queue_draw', 'void', ['pointer']),
    getWidth: nativeFn(gtk, 'gtk_widget_get_width', 'int', ['pointer']),
    getHeight: nativeFn(gtk, 'gtk_widget_get_height', 'int', ['pointer']),
    getFirstChild: nativeFn(gtk, 'gtk_widget_get_first_child', 'pointer', ['pointer']),
    getNextSibling: nativeFn(gtk, 'gtk_widget_get_next_sibling', 'pointer', ['pointer']),
    hasCssClass: nativeFn(gtk, 'gtk_widget_has_css_class', 'int', ['pointer', 'pointer']),
    getCssClasses: nativeFn(gtk, 'gtk_widget_get_css_classes', 'pointer', ['pointer']),
    activate: nativeFn(gtk, 'gtk_widget_activate', 'int', ['pointer']),
};

const ListBox = {
    selectRow: nativeFn(gtk, 'gtk_list_box_select_row', 'void', ['pointer', 'pointer']),
    getRowAtIndex: nativeFn(gtk, 'gtk_list_box_get_row_at_index', 'pointer', ['pointer', 'int']),
};

const Label = {
    getText: nativeFn(gtk, 'gtk_label_get_text', 'pointer', ['pointer']),
};

const Renderer = {
    renderTexture: nativeFn(gtk, 'gsk_renderer_render_texture', 'pointer', ['pointer', 'pointer', 'pointer']),
    realizeForDisplay: nativeFn(gtk, 'gsk_renderer_realize_for_display', 'int', ['pointer', 'pointer', 'pointer']),
    unrealize: nativeFn(gtk, 'gsk_renderer_unrealize', 'void', ['pointer']),
    cairoNew: nativeFn(gtk, 'gsk_cairo_renderer_new', 'pointer', []),
};

const RenderNode = {
    ref: nativeFn(gtk, 'gsk_render_node_ref', 'pointer', ['pointer']),
    unref: nativeFn(gtk, 'gsk_render_node_unref', 'void', ['pointer']),
};

const typeCache = new Map();
function gType(name) {
    let t = typeCache.get(name);
    if (t === undefined || (typeof t === 'number' ? t === 0 : t.equals(0))) {
        t = GObject.typeFromName(Memory.allocUtf8String(name));
        typeCache.set(name, t);
    }
    return t;
}
function isLabel(widget) {
    return GObject.typeCheckInstanceIsA(widget, gType('GtkLabel')) !== 0;
}
function isListBox(widget) {
    return GObject.typeCheckInstanceIsA(widget, gType('GtkListBox')) !== 0;
}

let captureResolve = null;
let capturePendingNode = null;

rpc.exports = {
    waitForWindow(timeoutMs) {
        return new Promise((resolve, reject) => {
            const deadline = Date.now() + timeoutMs;
            const poll = () => {
                scheduleIdle(() => {
                    const win = activeWindow();
                    if (!win.isNull()) {
                        resolve(true);
                        return;
                    }
                    if (Date.now() >= deadline) {
                        reject(new Error('window did not appear within ' + timeoutMs + 'ms'));
                        return;
                    }
                    setTimeout(poll, 100);
                });
            };
            poll();
        });
    },

    windowSize() {
        return runOnMainThread(() => {
            const win = activeWindow();
            return [Widget.getWidth(win), Widget.getHeight(win)];
        });
    },

    captureScreenshot() {
        return new Promise(resolve => {
            captureResolve = resolve;
            scheduleIdle(() => {
                const win = activeWindow();
                Widget.queueDraw(win);
                GdkSurface.queueRender(Native.getSurface(win));
            });
            setTimeout(() => {
                if (captureResolve === null)
                    return;
                captureResolve(null);
                captureResolve = null;
            }, 5000);
        });
    },

    listSidebar() {
        return runOnMainThread(() => {
            const items = [];
            for (const lb of collectListBoxes(activeWindow())) {
                for (let i = 0; ; i++) {
                    const row = ListBox.getRowAtIndex(lb, i);
                    if (row.isNull())
                        break;
                    items.push({ lb: lb.toString(), index: i, label: rowLabelText(row) });
                }
            }
            return items;
        });
    },

    selectSidebarRow(lbAddr, index) {
        return runOnMainThread(() => {
            const lb = ptr(lbAddr);
            const row = ListBox.getRowAtIndex(lb, index);
            if (row.isNull())
                return false;
            ListBox.selectRow(lb, row);
            return true;
        });
    },

    joinLab(labID) {
        return runOnMainThread(() => {
            const app = Application.getDefault();
            if (app.isNull())
                throw new Error('No GApplication');
            const uri = Memory.allocUtf8String('luma://join?lab=' + labID);
            const file = Gio.fileNewForUri(uri);
            const arr = Memory.alloc(Process.pointerSize);
            arr.writePointer(file);
            Gio.applicationOpen(app, arr, 1, NULL);
            GObject.unref(file);
            return true;
        });
    },

    notebookEntryTitles() {
        return runOnMainThread(() =>
            appWindows().flatMap(w => collectHeadingsInside(w, 'notebook-entry')));
    },

    debugWindowSummary() {
        return runOnMainThread(() => {
            const windows = appWindows();
            return windows.map(w => ({
                pointer: w.toString(),
                cssClasses: cssClasses(w),
                childCount: countChildren(w),
                notebookEntryCount: countMatchingDescendants(w, 'notebook-entry'),
            }));
        });
    },

    debugListBoxes() {
        return runOnMainThread(() => {
            const out = [];
            for (const w of appWindows()) {
                for (const lb of collectListBoxes(w)) {
                    let rowCount = 0;
                    while (!ListBox.getRowAtIndex(lb, rowCount).isNull()) rowCount++;
                    out.push({
                        cssClasses: cssClasses(lb).join(','),
                        rowCount,
                    });
                }
            }
            return out;
        });
    },

    debugFirstNotebookEntry() {
        return runOnMainThread(() => {
            for (const w of appWindows()) {
                const card = findFirstWithCssClass(w, 'notebook-entry');
                if (card !== null)
                    return dumpSubtree(card, 0);
            }
            return '(no notebook-entry found)';
        });
    },

    sidebarSessionLabels() {
        return runOnMainThread(() =>
            appWindows().flatMap(w => collectListBoxLabels(w, 'sidebar-sessions')));
    },

    eventMessages() {
        return runOnMainThread(() => {
            const out = [];
            for (const w of appWindows()) {
                const pane = findFirstWithCssClass(w, 'event-stream-pane');
                if (pane === null)
                    continue;
                collectLabels(pane, out);
            }
            return out;
        });
    },

    eventCount() {
        return runOnMainThread(() => {
            let total = 0;
            for (const w of appWindows())
                total += countMatchingDescendants(w, 'luma-event-delta');
            return total;
        });
    },

    expandEventStream() {
        return runOnMainThread(() => {
            for (const w of appWindows()) {
                const button = findFirstWithCssClass(w, 'luma-event-stream-toggle');
                if (button !== null) {
                    Widget.activate(button);
                    return true;
                }
            }
            return false;
        });
    },

    selectReplRow() {
        return selectSidebarRowByLabel('REPL');
    },

    selectTracerRow() {
        return selectSidebarRowByLabel('Tracer');
    },

    monacoLatestText() {
        return latestMonacoText;
    },

    replCellCodes() {
        return runOnMainThread(() =>
            appWindows().flatMap(w => collectAllLabels(w, 'repl-cell-code')));
    },
};

Interceptor.attach(gtk.getExportByName('gsk_renderer_render'), {
    onEnter(args) {
        if (captureResolve === null)
            return;
        capturePendingNode = args[1];
        RenderNode.ref(capturePendingNode);
    },
    onLeave() {
        if (capturePendingNode === null || captureResolve === null)
            return;

        const node = capturePendingNode;
        capturePendingNode = null;

        const resolve = captureResolve;
        captureResolve = null;

        resolve(renderNodeToRgba(node));
    },
});

function renderNodeToRgba(node) {
    const cairo = Renderer.cairoNew();
    Renderer.realizeForDisplay(cairo, GdkDisplay.getDefault(), NULL);
    const texture = Renderer.renderTexture(cairo, node, NULL);
    RenderNode.unref(node);
    Renderer.unrealize(cairo);
    GObject.unref(cairo);

    if (texture.isNull())
        return null;

    const w = GdkTexture.getWidth(texture);
    const h = GdkTexture.getHeight(texture);
    const stride = w * 4;
    const header = 8;
    const buf = Memory.alloc(header + stride * h);
    buf.writeU32(w);
    buf.add(4).writeU32(h);
    GdkTexture.download(texture, buf.add(header), stride);
    GObject.unref(texture);

    return buf.readByteArray(header + stride * h);
}

function activeWindow() {
    const app = Application.getDefault();
    if (app.isNull())
        return NULL;
    return GtkApplication.getActiveWindow(app);
}

function runOnMainThread(callback) {
    return new Promise((resolve, reject) => {
        scheduleIdle(() => {
            try {
                resolve(callback());
            } catch (e) {
                reject(e);
            }
        });
    });
}

function scheduleIdle(callback) {
    const idle = new NativeCallback(() => {
        pinned.splice(pinned.indexOf(idle), 1);
        callback();
        return 0;
    }, 'int', ['pointer']);
    pinned.push(idle);
    GLib.idleAdd(idle, NULL);
}

function collectHeadingsInside(root, containerClass) {
    const out = [];
    if (root.isNull())
        return out;
    const stack = [root];
    while (stack.length > 0) {
        const widget = stack.pop();
        if (widgetHasCssClass(widget, containerClass)) {
            const heading = findFirstLabelWithClass(widget, 'heading');
            if (heading !== null)
                out.push(labelText(heading));
            continue;
        }
        for (let child = Widget.getFirstChild(widget);
             !child.isNull();
             child = Widget.getNextSibling(child))
            stack.push(child);
    }
    return out;
}

function findFirstLabelWithClass(widget, cssTag) {
    if (isLabel(widget) && widgetHasCssClass(widget, cssTag))
        return widget;
    for (let child = Widget.getFirstChild(widget);
         !child.isNull();
         child = Widget.getNextSibling(child)) {
        const found = findFirstLabelWithClass(child, cssTag);
        if (found !== null)
            return found;
    }
    return null;
}

function collectListBoxLabels(root, cssTag) {
    const out = [];
    if (root.isNull())
        return out;
    for (const lb of collectListBoxes(root)) {
        if (cssTag !== null && !widgetHasCssClass(lb, cssTag))
            continue;
        for (let i = 0; ; i++) {
            const row = ListBox.getRowAtIndex(lb, i);
            if (row.isNull())
                break;
            const label = findFirstLabelWithClass(row, 'title-4') ?? firstLabel(row);
            if (label !== null)
                out.push(labelText(label));
        }
    }
    return out;
}

function collectAllLabels(root, cssTag) {
    const out = [];
    if (root.isNull())
        return out;
    const stack = [root];
    while (stack.length > 0) {
        const widget = stack.pop();
        if (widgetHasCssClass(widget, cssTag) && isLabel(widget))
            out.push(labelText(widget));
        for (let child = Widget.getFirstChild(widget);
             !child.isNull();
             child = Widget.getNextSibling(child))
            stack.push(child);
    }
    return out;
}

function widgetHasCssClass(widget, cssTag) {
    if (cssTag === null || cssTag === undefined)
        return true;
    return Widget.hasCssClass(widget, Memory.allocUtf8String(cssTag)) !== 0;
}

function countChildren(widget) {
    if (widget.isNull())
        return 0;
    let total = 0;
    for (let child = Widget.getFirstChild(widget);
         !child.isNull();
         child = Widget.getNextSibling(child))
        total++;
    return total;
}

function collectLabels(root, out) {
    if (root.isNull())
        return;
    if (isLabel(root)) {
        const t = labelText(root);
        if (t !== '')
            out.push(t);
    }
    for (let child = Widget.getFirstChild(root);
         !child.isNull();
         child = Widget.getNextSibling(child))
        collectLabels(child, out);
}

function countMatchingDescendants(root, cssTag) {
    let total = 0;
    if (root.isNull())
        return 0;
    const stack = [root];
    while (stack.length > 0) {
        const widget = stack.pop();
        if (widgetHasCssClass(widget, cssTag))
            total++;
        for (let child = Widget.getFirstChild(widget);
             !child.isNull();
             child = Widget.getNextSibling(child))
            stack.push(child);
    }
    return total;
}

function findFirstWithCssClass(root, cssTag) {
    if (root.isNull())
        return null;
    if (widgetHasCssClass(root, cssTag))
        return root;
    for (let child = Widget.getFirstChild(root);
         !child.isNull();
         child = Widget.getNextSibling(child)) {
        const found = findFirstWithCssClass(child, cssTag);
        if (found !== null)
            return found;
    }
    return null;
}

function dumpSubtree(widget, depth) {
    const indent = '  '.repeat(depth);
    const typeName = gTypeName(widget);
    const labelLike = isLabel(widget);
    const classes = cssClasses(widget).join(',');
    let line = `${indent}${typeName} [${classes}]`;
    if (labelLike)
        line += ` text=${JSON.stringify(labelText(widget))}`;
    let out = line + '\n';
    for (let child = Widget.getFirstChild(widget);
         !child.isNull();
         child = Widget.getNextSibling(child))
        out += dumpSubtree(child, depth + 1);
    return out;
}

function gTypeName(instance) {
    // GTypeInstance: first field is GTypeClass*; GTypeClass: first field is GType.
    const klass = instance.readPointer();
    if (klass.isNull())
        return '?';
    const gtype = klass.readU64();
    const namePtr = GObject.typeName(gtype);
    return namePtr.isNull() ? '?' : namePtr.readUtf8String();
}

function cssClasses(widget) {
    const arr = Widget.getCssClasses(widget);
    if (arr.isNull())
        return [];
    const out = [];
    let i = 0;
    while (true) {
        const ptr = arr.add(i * Process.pointerSize).readPointer();
        if (ptr.isNull())
            break;
        out.push(ptr.readUtf8String());
        i++;
    }
    return out;
}

function collectListBoxes(root) {
    const out = [];
    if (root.isNull())
        return out;
    const stack = [root];
    while (stack.length > 0) {
        const widget = stack.pop();
        if (isListBox(widget))
            out.push(widget);
        for (let child = Widget.getFirstChild(widget);
             !child.isNull();
             child = Widget.getNextSibling(child))
            stack.push(child);
    }
    return out;
}

function rowLabelText(row) {
    const lbl = firstLabel(row);
    if (lbl === null)
        return '';
    return labelText(lbl);
}

function labelText(label) {
    const t = Label.getText(label);
    return t.isNull() ? '' : t.readUtf8String();
}

function selectSidebarRowByLabel(targetLabel) {
    return runOnMainThread(() => {
        for (const w of appWindows()) {
            for (const lb of collectListBoxes(w)) {
                if (!widgetHasCssClass(lb, 'sidebar-sessions'))
                    continue;
                for (let i = 0; ; i++) {
                    const row = ListBox.getRowAtIndex(lb, i);
                    if (row.isNull())
                        break;
                    const label = firstLabel(row);
                    if (label !== null && labelText(label) === targetLabel) {
                        ListBox.selectRow(lb, row);
                        return true;
                    }
                }
            }
        }
        return false;
    });
}

function firstLabel(widget) {
    if (isLabel(widget))
        return widget;
    for (let child = Widget.getFirstChild(widget);
         !child.isNull();
         child = Widget.getNextSibling(child)) {
        const found = firstLabel(child);
        if (found !== null)
            return found;
    }
    return null;
}

function findModule(prefix) {
    const m = Process.enumerateModules().find(m => m.name.startsWith(prefix));
    if (!m)
        throw new Error('Module not found: ' + prefix);
    return m;
}

function nativeFn(mod, name, ret, args) {
    return new NativeFunction(mod.getExportByName(name), ret, args);
}
