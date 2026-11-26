import { Buffer } from "buffer";
import { Controller as StreamController } from "frida-remote-stream";
import { Writable } from "stream";
import { encodeValue } from "./value.js";

export interface Instrument<C = unknown, R = unknown> {
    create(
        ctx: InstrumentContext,
        initialConfig: C,
        restored: R
    ): InstrumentHandle<C> | Promise<InstrumentHandle<C>>;
}

export interface InstrumentContext {
    instanceId: string;
    emit(payload: unknown): void;
    post(type: string, payload: object, data?: ArrayBuffer | ArrayBufferView | number[] | null): void;
    widget(id: string): WidgetHandle;
    children(template: string): ChildrenHandle;
}

export interface ChildrenHandle {
    add(id: string, row: ChildRow): ChildHandle;
    get(id: string): ChildHandle | undefined;
    ids(): string[];
    remove(id: string): void;
}

export interface ChildRow {
    title: string;
    subtitle?: string;
    badge?: ChildBadge | null;
}

export interface ChildBadge {
    text: string;
    tone?: "neutral" | "active" | "waiting" | "ended" | "failed";
}

export interface ChildHandle {
    readonly template: string;
    readonly id: string;
    update(row: Partial<ChildRow>): void;
    widget(id: string): WidgetHandle;
    remove(): void;
}

export interface ChildRef {
    template: string;
    id: string;
}

export interface WidgetHandle {
    setCounter(value: CounterValue): void;
    setHistogram(buckets: HistogramBucket[]): void;
    incrementBucket(label: string, by?: number): void;
    push(point: GraphPoint): void;
    upsertItem(item: ListItem): void;
    removeItem(id: string): void;
    upsertRow(row: TableRow): void;
    removeRow(id: string): void;
    setHex(state: HexValue): void;
    appendConsole(entry: ConsoleEntry): void;
    appendOutput(text: string): void;
    appendError(text: string): void;
    appendValue(value: unknown): void;
    appendImage(image: ConsoleImage): void;
    setState(value: unknown, data?: ViewData | null): void;
    sendEvent(value: unknown, data?: ViewData | null): void;
    setActionEnabled(action: string, enabled: boolean): void;
    clear(): void;
}

export type ViewData = ArrayBuffer | ArrayBufferView | number[];

export interface CounterValue {
    value: number;
    unit?: string;
    delta?: number;
    fractionDigits?: number;
}

export interface HistogramBucket {
    label: string;
    count: number;
}

export interface GraphPoint {
    series: string;
    x: number;
    y: number;
}

export interface ListItem {
    id: string;
    title: string;
    subtitle?: string;
    accessory?: string;
}

export interface TableRow {
    id: string;
    cells: { [columnId: string]: string };
}

export interface HexValue {
    bytes: ArrayBuffer | number[];
    baseAddress?: number | string | NativePointer;
}

export interface ConsoleEntry {
    id?: string;
    kind: "input" | "output" | "error";
    text: string;
}

export interface ConsoleImage {
    bytes: ArrayBuffer | Uint8Array | number[];
    mediaType: string;
    width: number;
    height: number;
    text?: string;
}

export interface WidgetAction {
    widget: string;
    action: string;
    item?: string;
    child?: ChildRef;
}

export interface ConsoleInput {
    widget: string;
    entryId: string;
    text: string;
    child?: ChildRef;
}

export interface ViewMessage {
    widget: string;
    value: unknown;
    data: ArrayBuffer | null;
    from?: { id: string; name: string };
    child?: ChildRef;
}

export interface OfferedFileHeader {
    name: string;
    mediaType: string;
}

export interface OfferedFile extends OfferedFileHeader {
    bytes: ArrayBuffer | ArrayBufferView | number[];
}

export interface OfferFile {
    (file: OfferedFile): void;
    (file: OfferedFileHeader): Writable;
}

export interface ActionResponder {
    file: OfferFile;
    show(child: ChildHandle | null): void;
}

export interface ConsoleResponder {
    output(text: string): void;
    error(text: string): void;
    value(v: unknown): void;
    image(img: ConsoleImage): void;
    file: OfferFile;
    show(child: ChildHandle | null): void;
}

export interface InstrumentHandle<C = unknown> {
    updateConfig?(config: C): Promise<void> | void;
    onAction?(action: WidgetAction, respond: ActionResponder): Promise<void> | void;
    onConsoleInput?(input: ConsoleInput, respond: ConsoleResponder): Promise<void> | void;
    onViewMessage?(message: ViewMessage): Promise<void> | void;
    dispose?(): Promise<void> | void;
}

interface InstrumentController {
    instrument: Instrument;
    config: unknown;
    handle: InstrumentHandle;
}

interface InstrumentModule {
    instrument: Instrument;
}

const instruments = new Map<string, InstrumentController>();
const modules = new Map<string, Instrument>();

const viewLimits = {
    valueBytes: 256 * 1024,
    stateDataBytes: 64 * 1024 * 1024,
    eventDataBytes: 1024 * 1024,
    stateDataPieceBytes: 4 * 1024 * 1024 - 64 * 1024,
};

const fileLimits = {
    bytes: 64 * 1024 * 1024,
    nameBytes: 255,
    chunkBytes: 4 * 1024 * 1024,
};

const fileStreams = new StreamController();
const openFileStreams = new Map<string, Set<OfferedFileStream>>();

fileStreams.events.on("send", ({ stanza, data }) => {
    sendNow({ type: "luma:stream", stanza }, data === null ? null : new Uint8Array(data).buffer);
});

function receiveFileStreamReplies(): void {
    recv("luma:stream", (message: { stanza: { [key: string]: any } }) => {
        receiveFileStreamReplies();
        fileStreams.receive({ stanza: message.stanza, data: null });
    });
}

receiveFileStreamReplies();

declare global {
    function send(message: any, data?: ArrayBuffer | ArrayBufferView | number[] | null): void;
}

interface ViewMessageEnvelope {
    instance_id: string;
    widget: string;
    child?: ChildRef;
    value: unknown;
    from?: { id: string; name: string };
}

function receiveViewMessages(): void {
    recv("luma:view-message", (message: ViewMessageEnvelope, data: ArrayBuffer | null) => {
        receiveViewMessages();
        const handle = instruments.get(message.instance_id)?.handle;
        if (handle?.onViewMessage === undefined) {
            return;
        }
        const delivered: ViewMessage = { widget: message.widget, value: message.value, data };
        if (message.from !== undefined) {
            delivered.from = message.from;
        }
        if (message.child !== undefined) {
            delivered.child = message.child;
        }
        handle.onViewMessage(delivered);
    });
}

receiveViewMessages();

export async function loadInstrument({ instanceId, moduleName, source, config, restored, childTemplates, marker }: {
    instanceId: string,
    moduleName: string,
    source: string,
    config: unknown,
    restored: { children?: { [template: string]: { [id: string]: ChildRow } } },
    childTemplates: string[],
    marker: string,
}): Promise<void> {
    try {
        const instrument = await loadInstrumentModule(moduleName, source);
        liveInstances.add(instanceId);
        const ctx = makeInstrumentContext(instanceId, childTemplates, restored.children ?? {});

        ctx.post("instrument-actions-reset", {});
        let handle: InstrumentHandle;
        try {
            handle = await instrument.create(ctx, config, withHexPointers(restored));
        } catch (e) {
            forgetInstance(instanceId);
            throw e;
        }

        const controller: InstrumentController = {
            instrument,
            config,
            handle,
        };

        instruments.set(instanceId, controller);
    } finally {
        markHandled(marker);
    }
}

export async function updateInstrumentConfig({ instanceId, config, marker }: {
    instanceId: string,
    config: unknown,
    marker: string,
}): Promise<void> {
    try {
        const controller = instruments.get(instanceId);
        if (controller === undefined) {
            throw new Error(`No such instance: ${instanceId}`);
        }

        controller.config = config;

        await controller.handle.updateConfig?.(config);
    } finally {
        markHandled(marker);
    }
}

export async function disposeInstrument({ instanceId }: { instanceId: string }): Promise<void> {
    const controller = instruments.get(instanceId);
    if (controller === undefined) {
        throw new Error(`No such instance: ${instanceId}`);
    }

    await controller.handle.dispose?.();

    for (const stream of openFileStreams.get(instanceId) ?? []) {
        stream.destroy(new Error("the instrument was unloaded"));
    }
    instruments.delete(instanceId);
    forgetInstance(instanceId);
}

function forgetInstance(instanceId: string): void {
    flushBatches();
    liveInstances.delete(instanceId);
    budgets.delete(instanceId);
}

export async function invokeWidgetAction({ instanceId, widget, child, action, item, actionId, savesFile, marker }: {
    instanceId: string,
    widget: string,
    child?: ChildRef,
    action: string,
    item?: string,
    actionId: string,
    savesFile: boolean,
    marker: string,
}): Promise<HandlerOutcome> {
    try {
        const controller = instruments.get(instanceId);
        if (controller === undefined) {
            throw new Error(`No such instance: ${instanceId}`);
        }

        const chosen: WidgetAction = { widget, action };
        if (item !== undefined) {
            chosen.item = item;
        }
        if (child !== undefined) {
            chosen.child = child;
        }
        const offer = makeFileOffer(instanceId, actionId, savesFile, "onAction", "action");
        let error: string | null = null;
        try {
            await controller.handle.onAction?.(chosen, { file: offer.file, show: offer.show });
        } catch (e) {
            error = (e instanceof Error) ? e.message : String(e);
        }
        offer.close();
        return { file: offer.offered(), error, show: offer.shown() };
    } finally {
        markHandled(marker);
    }
}

export async function submitConsoleInput({ instanceId, widget, child, entryId, text, actionId, savesFile, marker }: {
    instanceId: string,
    widget: string,
    child?: ChildRef,
    entryId: string,
    text: string,
    actionId: string,
    savesFile: boolean,
    marker: string,
}): Promise<HandlerOutcome> {
    try {
        const controller = instruments.get(instanceId);
        if (controller === undefined) {
            throw new Error(`No such instance: ${instanceId}`);
        }

        const offer = makeFileOffer(instanceId, actionId, savesFile, "onConsoleInput", "input");
        const respond = makeConsoleResponder(instanceId, widget, child, entryId, offer);
        const input: ConsoleInput = { widget, entryId, text };
        if (child !== undefined) {
            input.child = child;
        }
        try {
            await controller.handle.onConsoleInput?.(input, respond);
        } catch (e) {
            respond.error((e instanceof Error) ? e.message : String(e));
        }
        offer.close();
        queue(instanceId, {
            type: "widget-console-reply-done",
            instance_id: instanceId,
            widget,
            child,
            reply_to: entryId,
        }, null);
        return { file: offer.offered(), error: null, show: offer.shown() };
    } finally {
        markHandled(marker);
    }
}

interface HandlerOutcome {
    file: { name: string, media_type: string, size: number | null } | null;
    error: string | null;
    show: { child: ChildRef | null } | null;
}

function makeFileOffer(
    instanceId: string,
    actionId: string,
    savesFile: boolean,
    handlerName: string,
    trigger: string
): { file: OfferFile, show(child: ChildHandle | null): void, close(): void, offered(): HandlerOutcome["file"], shown(): HandlerOutcome["show"] } {
    let closed = false;
    let offered: HandlerOutcome["file"] = null;
    let shown: HandlerOutcome["show"] = null;
    function file(file: OfferedFile): void;
    function file(file: OfferedFileHeader): Writable;
    function file(file: OfferedFileHeader | OfferedFile): Writable | void {
        if (closed) {
            throw new Error(`respond.file: offered after ${handlerName} returned`);
        }
        if (offered !== null) {
            throw new Error(`respond.file: this ${trigger} has already offered a file`);
        }
        const { name, mediaType } = file;
        const nameProblem = fileNameProblem(name);
        if (nameProblem !== null) {
            throw new TypeError(`respond.file: ${JSON.stringify(name)} is not a plain file name: ${nameProblem}`);
        }
        if (!mediaTypePattern.test(mediaType)) {
            throw new TypeError(`respond.file: ${JSON.stringify(mediaType)} is not a media type such as "model/obj"`);
        }
        const bytes = ("bytes" in file) ? viewDataBytes(file.bytes) : null;
        if (bytes !== null && bytes.byteLength > fileLimits.bytes) {
            throw new RangeError(`respond.file: ${JSON.stringify(name)} is ${bytes.byteLength} bytes; the most a file can be is ${fileLimits.bytes} (64 MiB)`);
        }
        offered = { name, media_type: mediaType, size: bytes?.byteLength ?? null };
        const sink = savesFile
            ? fileStreams.open("offered-file", { action_id: actionId, instance_id: instanceId, name, media_type: mediaType })
            : null;
        const stream = new OfferedFileStream(sink, actionId);
        const open = openFileStreams.get(instanceId) ?? new Set();
        openFileStreams.set(instanceId, open.add(stream));
        stream.once("close", () => open.delete(stream));
        if (bytes === null) {
            return stream;
        }
        stream.end(Buffer.from(bytes));
    }
    return {
        file,
        show(child) {
            if (closed) {
                throw new Error(`respond.show: called after ${handlerName} returned`);
            }
            shown = { child: child === null ? null : { template: child.template, id: child.id } };
        },
        close() {
            closed = true;
        },
        offered() {
            return offered;
        },
        shown() {
            return shown;
        },
    };
}

class OfferedFileStream extends Writable {
    #sink: Writable | null;
    #actionId: string;
    #pending: Buffer[] = [];
    #pendingBytes = 0;
    #total = 0;
    #refused = false;

    constructor(sink: Writable | null, actionId: string) {
        super();
        this.#sink = sink;
        this.#actionId = actionId;
        this.on("error", () => {});
        sink?.on("error", () => {});
    }

    _write(chunk: Buffer, _encoding: BufferEncoding, callback: (error?: Error | null) => void): void {
        this.#total += chunk.length;
        if (this.#total > fileLimits.bytes) {
            callback(new RangeError(`respond.file: the file grew past ${fileLimits.bytes} bytes (64 MiB)`));
            return;
        }
        this.#pending.push(chunk);
        this.#pendingBytes += chunk.length;
        this.#flush(fileLimits.chunkBytes, callback);
    }

    _final(callback: (error?: Error | null) => void): void {
        this.#flush(1, error => {
            if (error !== null && error !== undefined) {
                callback(error);
            } else if (this.#sink === null) {
                callback();
            } else {
                this.#sink.end(callback);
            }
        });
    }

    _destroy(error: Error | null, callback: (error?: Error | null) => void): void {
        if (!this.writableFinished && !this.#refused && this.#sink !== null) {
            sendNow({ type: "luma:stream-abort", action_id: this.#actionId, reason: error?.message ?? "the instrument stopped writing" }, null);
        }
        this.#sink?.destroy();
        callback(error);
    }

    #flush(threshold: number, callback: (error?: Error | null) => void): void {
        if (this.#pendingBytes === 0 || this.#pendingBytes < threshold) {
            callback();
            return;
        }
        const piece = this.#take(fileLimits.chunkBytes);
        if (this.#sink === null) {
            this.#flush(threshold, callback);
            return;
        }
        this.#sink.write(piece, error => {
            if (error !== null && error !== undefined) {
                this.#refused = true;
                callback(error);
            } else {
                this.#flush(threshold, callback);
            }
        });
    }

    #take(count: number): Buffer {
        const all = Buffer.concat(this.#pending);
        const rest = all.subarray(count);
        this.#pending = rest.length > 0 ? [rest] : [];
        this.#pendingBytes = rest.length;
        return all.subarray(0, count);
    }
}

const mediaTypePattern = /^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}$/;

function fileNameProblem(name: string): string | null {
    if (name.length === 0) {
        return "it is empty";
    }
    if (utf8Length(name) > fileLimits.nameBytes) {
        return `it is longer than ${fileLimits.nameBytes} bytes as UTF-8`;
    }
    const reserved = [...name].find(c => '/\\<>:"|?*'.includes(c));
    if (reserved !== undefined) {
        return `it contains ${JSON.stringify(reserved)}`;
    }
    if ([...name].some(c => c.codePointAt(0)! < 0x20 || c.codePointAt(0) === 0x7f)) {
        return "it contains a control character";
    }
    if (name.startsWith(".")) {
        return "it starts with a dot";
    }
    if (name.endsWith(".") || name.endsWith(" ")) {
        return `it ends with ${name.endsWith(".") ? "a dot" : "a space"}`;
    }
    return null;
}

function makeConsoleResponder(
    instanceId: string,
    widget: string,
    child: ChildRef | undefined,
    replyTo: string,
    { file, show }: Pick<ConsoleResponder, "file" | "show">
): ConsoleResponder {
    const postEntry = (
        entry: {
            kind: "output" | "error" | "image";
            text: string;
            value?: unknown;
            image?: { media_type: string; width: number; height: number };
        },
        data: ArrayBuffer | null
    ) => {
        queue(instanceId, {
            type: "widget-console-append",
            instance_id: instanceId,
            widget,
            child,
            entry: {
                id: makeId(),
                kind: entry.kind,
                text: entry.text,
                value: entry.value,
                image: entry.image,
                reply_to: replyTo,
            },
        }, data);
    };
    return {
        output(text) {
            postEntry({ kind: "output", text }, null);
        },
        error(text) {
            postEntry({ kind: "error", text }, null);
        },
        value(v) {
            const [tree, blob] = encodeValue(v);
            postEntry({ kind: "output", text: "", value: tree }, blob);
        },
        image(img) {
            postEntry(
                {
                    kind: "image",
                    text: img.text ?? "",
                    image: { media_type: img.mediaType, width: img.width, height: img.height },
                },
                consoleImageBuffer(img.bytes)
            );
        },
        file,
        show,
    };
}

async function loadInstrumentModule(
    moduleName: string,
    source: string
): Promise<Instrument> {
    const cached = modules.get(moduleName);
    if (cached !== undefined) {
        return cached;
    }

    const ns = await Script.load(moduleName, source);
    const instrument = parseInstrumentModule(ns, moduleName);

    modules.set(moduleName, instrument);

    return instrument;
}

function parseInstrumentModule(ns: unknown, name: string): Instrument {
    const { instrument } = ns as { instrument?: Instrument };
    if (typeof instrument?.create !== "function") {
        throw new Error(`Instrument module ${name} does not export a valid instrument`);
    }
    return instrument;
}

function makeInstrumentContext(
    instanceId: string,
    childTemplates: string[],
    restoredChildren: { [template: string]: { [id: string]: ChildRow } }
): InstrumentContext {
    const post = (type: string, payload: object, data?: ArrayBuffer | ArrayBufferView | number[] | null) => {
        queue(instanceId, {
            type,
            instance_id: instanceId,
            ...payload,
        }, data ?? null);
    };
    return {
        instanceId,
        emit(payload: unknown) {
            const [tree, blob] = encodeValue(payload);
            queue(instanceId, {
                type: "instrument-event",
                instance_id: instanceId,
                payload: tree,
            }, blob);
        },
        post,
        widget(id: string): WidgetHandle {
            return makeWidgetHandle(post, id);
        },
        children: makeChildren(post, childTemplates, restoredChildren),
    };
}

type RestoredWidgets = { [widgetId: string]: unknown };

function withHexPointers(restored: { children?: { [template: string]: { [id: string]: ChildRow } } }): object {
    const { children, ...widgets } = restored;
    if (children === undefined) {
        return hexPointersIn(widgets);
    }
    return {
        ...hexPointersIn(widgets),
        children: Object.fromEntries(Object.entries(children).map(([template, rows]) => [
            template,
            Object.fromEntries(Object.entries(rows).map(([id, row]) => {
                const { widgets: rowWidgets } = row as ChildRow & { widgets?: RestoredWidgets };
                return [id, rowWidgets === undefined ? row : { ...row, widgets: hexPointersIn(rowWidgets) }];
            })),
        ])),
    };
}

function hexPointersIn(widgets: RestoredWidgets): RestoredWidgets {
    return Object.fromEntries(Object.entries(widgets).map(([widgetId, value]) => {
        const hex = (value as { hex?: { bytes: string, base_address: string } | null } | null)?.hex;
        return [widgetId, hex == null ? value : { hex: { ...hex, base_address: ptr(hex.base_address) } }];
    }));
}

type Post = (type: string, payload: object, data?: ArrayBuffer | ArrayBufferView | number[] | null) => void;

function makeChildren(
    post: Post,
    templates: string[],
    restored: { [template: string]: { [id: string]: ChildRow } }
): (template: string) => ChildrenHandle {
    const live = new Map<string, Map<string, ChildHandle>>(templates.map(t => [t, new Map()]));
    const count = () => [...live.values()].reduce((sum, children) => sum + children.size, 0);
    const handleFor = (template: string, id: string, row: ChildRow): ChildHandle => {
        const ref = { template, id };
        let current = { ...row };
        const handle: ChildHandle = {
            template,
            id,
            update(change) {
                current = { ...current, ...change };
                postChild(post, ref, current);
            },
            widget(widgetId: string): WidgetHandle {
                return makeWidgetHandle((type, payload, data) => post(type, { ...payload, child: ref }, data), widgetId);
            },
            remove() {
                if (live.get(template)?.delete(id) !== true) {
                    throw new Error(`child ${JSON.stringify(id)} of ${JSON.stringify(template)} was already removed`);
                }
                post("instrument-child-remove", { child: ref });
            },
        };
        return handle;
    };
    for (const [template, children] of Object.entries(restored)) {
        for (const [id, row] of Object.entries(children)) {
            live.get(template)?.set(id, handleFor(template, id, row));
        }
    }
    return (template: string) => {
        const children = live.get(template);
        if (children === undefined) {
            throw new TypeError(`ctx.children: ${JSON.stringify(template)} is not a kind of child this instrument declares`);
        }
        return {
            add(id, row) {
                checkChildRow(id, row);
                const existing = children.get(id);
                if (existing !== undefined) {
                    existing.update(row);
                    return existing;
                }
                if (count() >= childLimits.perInstance) {
                    throw new RangeError(`ctx.children: the most children an instance can have is ${childLimits.perInstance}`);
                }
                const child = handleFor(template, id, row);
                children.set(id, child);
                postChild(post, { template, id }, row);
                return child;
            },
            get(id) {
                return children.get(id);
            },
            ids() {
                return [...children.keys()];
            },
            remove(id) {
                const child = children.get(id);
                if (child === undefined) {
                    throw new Error(`ctx.children: there is no child ${JSON.stringify(id)} of ${JSON.stringify(template)}`);
                }
                child.remove();
            },
        };
    };
}

const childLimits = {
    perInstance: 256,
    idLength: 128,
    titleLength: 120,
    subtitleLength: 200,
    badgeLength: 32,
};

const badgeTones = ["neutral", "active", "waiting", "ended", "failed"];

function checkChildRow(id: string, row: ChildRow): void {
    if (id.length === 0 || id.length > childLimits.idLength) {
        throw new TypeError(`ctx.children: a child's id has to be 1 to ${childLimits.idLength} characters, not ${JSON.stringify(id)}`);
    }
    if (row.title.length === 0 || row.title.length > childLimits.titleLength) {
        throw new TypeError(`ctx.children: a child's title has to be 1 to ${childLimits.titleLength} characters`);
    }
    if ((row.subtitle?.length ?? 0) > childLimits.subtitleLength) {
        throw new TypeError(`ctx.children: a child's subtitle has at most ${childLimits.subtitleLength} characters`);
    }
    const badge = row.badge;
    if (badge !== undefined && badge !== null) {
        if (badge.text.length === 0 || badge.text.length > childLimits.badgeLength) {
            throw new TypeError(`ctx.children: a badge's text has to be 1 to ${childLimits.badgeLength} characters`);
        }
        if (badge.tone !== undefined && !badgeTones.includes(badge.tone)) {
            throw new TypeError(`ctx.children: ${JSON.stringify(badge.tone)} is not a badge tone; use one of ${badgeTones.join(", ")}`);
        }
    }
}

function postChild(post: Post, child: ChildRef, row: ChildRow): void {
    post("instrument-child", {
        child,
        title: row.title,
        subtitle: row.subtitle,
        badge: row.badge === undefined || row.badge === null ? undefined : { text: row.badge.text, tone: row.badge.tone ?? "neutral" },
    });
}

function makeWidgetHandle(post: Post, id: string): WidgetHandle {
    return {
        setCounter(value) {
            post("widget-counter-set", { widget: id, counter: value });
        },
        setHistogram(buckets) {
            post("widget-histogram-set", { widget: id, buckets });
        },
        incrementBucket(label, by = 1) {
            post("widget-histogram-increment", { widget: id, label, by });
        },
        push(point) {
            post("widget-graph-point", { widget: id, point });
        },
        upsertItem(item) {
            post("widget-list-upsert", { widget: id, item });
        },
        removeItem(itemId) {
            post("widget-list-remove", { widget: id, item: itemId });
        },
        upsertRow(row) {
            post("widget-table-upsert", { widget: id, row });
        },
        removeRow(rowId) {
            post("widget-table-remove", { widget: id, row: rowId });
        },
        setHex(state) {
            const data = state.bytes instanceof ArrayBuffer ? state.bytes : new Uint8Array(state.bytes).buffer;
            post("widget-hex-set", { widget: id, hex: { base_address: new NativePointer(state.baseAddress ?? 0).toString() } }, data);
        },
        appendConsole(entry) {
            post("widget-console-append", {
                widget: id,
                entry: {
                    id: entry.id ?? makeId(),
                    kind: entry.kind,
                    text: entry.text,
                },
            });
        },
        appendOutput(text) {
            post("widget-console-append", {
                widget: id,
                entry: { id: makeId(), kind: "output", text },
            });
        },
        appendError(text) {
            post("widget-console-append", {
                widget: id,
                entry: { id: makeId(), kind: "error", text },
            });
        },
        appendValue(value) {
            const [tree, blob] = encodeValue(value);
            post("widget-console-append", {
                widget: id,
                entry: { id: makeId(), kind: "output", text: "", value: tree },
            }, blob);
        },
        appendImage(image) {
            post("widget-console-append", {
                widget: id,
                entry: {
                    id: makeId(),
                    kind: "image",
                    text: image.text ?? "",
                    image: { media_type: image.mediaType, width: image.width, height: image.height },
                },
            }, consoleImageBuffer(image.bytes));
        },
        setState(value, data) {
            const [payload, bytes] = viewPayload("state", value, data, viewLimits.stateDataBytes);
            post("widget-view-state", { widget: id, ...payload, data_size: bytes?.byteLength ?? 0 });
            for (const piece of viewDataPieces(bytes)) {
                post("widget-view-state-data", { widget: id }, piece);
            }
        },
        sendEvent(value, data) {
            const [payload, bytes] = viewPayload("event", value, data, viewLimits.eventDataBytes);
            post("widget-view-event", { widget: id, ...payload }, bytes);
        },
        setActionEnabled(action, enabled) {
            post("widget-action-enabled", { widget: id, action, enabled });
        },
        clear() {
            post("widget-clear", { widget: id });
        },
    };
}

function viewPayload(kind: string, value: unknown, data: ViewData | null | undefined, maxDataBytes: number): [object, Uint8Array | null] {
    const json = JSON.stringify(value ?? null);
    const jsonBytes = utf8Length(json);
    if (jsonBytes > viewLimits.valueBytes) {
        throw new Error(`A view ${kind} value is ${jsonBytes} bytes of JSON as UTF-8; the most is ${viewLimits.valueBytes}`);
    }
    const bytes = (data === undefined || data === null) ? null : viewDataBytes(data);
    if (bytes !== null && bytes.byteLength > maxDataBytes) {
        throw new Error(`A view ${kind} carries ${bytes.byteLength} bytes of data; the most is ${maxDataBytes}`);
    }
    return [{ json }, bytes];
}

function viewDataPieces(bytes: Uint8Array | null): Uint8Array[] {
    const pieces: Uint8Array[] = [];
    for (let offset = 0; bytes !== null && offset < bytes.byteLength; offset += viewLimits.stateDataPieceBytes) {
        pieces.push(bytes.subarray(offset, offset + viewLimits.stateDataPieceBytes));
    }
    return pieces;
}

function utf8Length(text: string): number {
    let length = 0;
    for (const character of text) {
        const code = character.codePointAt(0)!;
        length += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
    }
    return length;
}

function viewDataBytes(data: ViewData): Uint8Array {
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    return new Uint8Array(data);
}

function consoleImageBuffer(bytes: ArrayBuffer | Uint8Array | number[]): ArrayBuffer {
    if (bytes instanceof ArrayBuffer) return bytes;
    if (bytes instanceof Uint8Array) return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    return new Uint8Array(bytes).buffer;
}

function makeId(): string {
    return Math.random().toString(36).slice(2, 10) + Math.random().toString(36).slice(2, 10);
}

type Message = { [key: string]: unknown };
type Payload = ArrayBuffer | ArrayBufferView | number[] | null;

const sourceBudget = {
    eventsPerSecond: 2000,
    widgetUpdatesPerSecond: 2000,
};

const batchLimits = {
    items: 1000,
    bytes: 4 * 1024 * 1024,
};

interface Batch {
    items: { message: Message, bytes: Uint8Array | null }[];
    size: number;
    latest: Map<string, number>;
}

interface Budget {
    windowStart: number;
    events: number;
    widgetUpdates: number;
    droppedEvents: number;
    droppedEntries: Map<string, { widget: unknown, child: unknown, count: number }>;
}

const liveInstances = new Set<string>();
const batches = new Map<string, Batch>();
const budgets = new Map<string, Budget>();
let flushScheduled = false;

function queue(instanceId: string, message: Message, data: Payload): void {
    if (!liveInstances.has(instanceId)) {
        return;
    }
    if (!admitted(instanceId, message)) {
        scheduleFlush();
        return;
    }
    const batch = batchOf(instanceId);
    const bytes = (data !== null) ? bytesOf(data) : null;
    const key = coalescingKey(message);
    const earlier = (key !== null) ? batch.latest.get(key) : undefined;
    if (earlier !== undefined) {
        batch.size -= batch.items[earlier].bytes?.byteLength ?? 0;
        batch.items[earlier] = { message, bytes };
    } else {
        forgetCoalescingAcross(batch, message);
        if (key !== null) {
            batch.latest.set(key, batch.items.length);
        }
        batch.items.push({ message, bytes });
    }
    batch.size += bytes?.byteLength ?? 0;
    if (batch.items.length >= batchLimits.items || batch.size >= batchLimits.bytes) {
        flushBatches();
        return;
    }
    scheduleFlush();
}

export function sendNow(message: Message, data: Payload = null): void {
    flushBatches();
    send(message, data);
}

function markHandled(marker: string): void {
    flushBatches();
    send({ type: "luma:marker", marker });
}

export function flushBatches(): void {
    flushScheduled = false;
    const instanceIds = new Set([...batches.keys(), ...budgets.keys()]);
    for (const instanceId of instanceIds) {
        const batch = batches.get(instanceId);
        batches.delete(instanceId);
        const items = batch?.items ?? [];
        let offset = 0;
        for (const { message, bytes } of items) {
            if (bytes !== null) {
                message.blob_offset = offset;
                message.blob_size = bytes.byteLength;
                offset += bytes.byteLength;
            }
        }
        const messages = [...items.map(item => item.message), ...droppedReports(instanceId)];
        if (messages.length === 0) {
            continue;
        }
        send({ type: "instrument-batch", instance_id: instanceId, items: messages }, (offset > 0) ? joined(items, offset) : null);
    }
}

function scheduleFlush(): void {
    if (flushScheduled) {
        return;
    }
    flushScheduled = true;
    Script.nextTick(flushBatches);
}

function admitted(instanceId: string, message: Message): boolean {
    const budget = budgetOf(instanceId);
    const now = Date.now();
    if (now - budget.windowStart >= 1000) {
        budget.windowStart = now;
        budget.events = 0;
        budget.widgetUpdates = 0;
    }
    if (message.type === "instrument-event") {
        if (budget.events >= sourceBudget.eventsPerSecond) {
            budget.droppedEvents++;
            return false;
        }
        budget.events++;
        return true;
    }
    if (typeof message.type !== "string" || !message.type.startsWith("widget-")) {
        return true;
    }
    if (budget.widgetUpdates >= sourceBudget.widgetUpdatesPerSecond && isDroppable(message)) {
        if (message.type === "widget-console-append") {
            const key = widgetKey(message);
            const dropped = budget.droppedEntries.get(key) ?? { widget: message.widget, child: message.child, count: 0 };
            dropped.count++;
            budget.droppedEntries.set(key, dropped);
        }
        return false;
    }
    budget.widgetUpdates++;
    return true;
}

function isDroppable(message: Message): boolean {
    if (message.type === "widget-graph-point") {
        return true;
    }
    return message.type === "widget-console-append" && (message.entry as { reply_to?: string } | undefined)?.reply_to === undefined;
}

function coalescingKey(message: Message): string | null {
    switch (message.type) {
        case "widget-counter-set":
        case "widget-hex-set":
            return keyOf([...widgetParts(message), message.type]);
        case "widget-table-upsert":
            return rowKey(message, "widget-table-upsert", (message.row as { id?: unknown }).id);
        case "widget-list-upsert":
            return rowKey(message, "widget-list-upsert", (message.item as { id?: unknown }).id);
        default:
            return null;
    }
}

function forgetCoalescingAcross(batch: Batch, message: Message): void {
    switch (message.type) {
        case "widget-table-remove":
            batch.latest.delete(rowKey(message, "widget-table-upsert", message.row) ?? "");
            break;
        case "widget-list-remove":
            batch.latest.delete(rowKey(message, "widget-list-upsert", message.item) ?? "");
            break;
        case "widget-clear":
            forgetKeysUnder(batch, widgetParts(message));
            break;
        case "instrument-child-remove":
            forgetKeysUnder(batch, childParts(message.child as ChildRef));
            break;
    }
}

function forgetKeysUnder(batch: Batch, parts: unknown[]): void {
    const prefix = keyOf(parts).slice(0, -1) + ",";
    for (const key of batch.latest.keys()) {
        if (key.startsWith(prefix)) {
            batch.latest.delete(key);
        }
    }
}

function rowKey(message: Message, upsertType: string, id: unknown): string | null {
    return (typeof id === "string") ? keyOf([...widgetParts(message), upsertType, id]) : null;
}

function widgetKey(message: Message): string {
    return keyOf(widgetParts(message));
}

function widgetParts(message: Message): unknown[] {
    const child = message.child as ChildRef | undefined;
    return (child !== undefined) ? [...childParts(child), message.widget] : ["widget", message.widget];
}

function childParts(child: ChildRef): unknown[] {
    return ["child", child.template, child.id];
}

function keyOf(parts: unknown[]): string {
    return JSON.stringify(parts);
}

function droppedReports(instanceId: string): Message[] {
    const budget = budgets.get(instanceId);
    if (budget === undefined) {
        return [];
    }
    const reports: Message[] = [];
    if (budget.droppedEvents > 0) {
        reports.push({ type: "instrument-events-dropped", instance_id: instanceId, count: budget.droppedEvents });
        budget.droppedEvents = 0;
    }
    for (const dropped of budget.droppedEntries.values()) {
        reports.push({ type: "widget-console-dropped", instance_id: instanceId, widget: dropped.widget, child: dropped.child, count: dropped.count });
    }
    budget.droppedEntries.clear();
    return reports;
}

function batchOf(instanceId: string): Batch {
    let batch = batches.get(instanceId);
    if (batch === undefined) {
        batch = { items: [], size: 0, latest: new Map() };
        batches.set(instanceId, batch);
    }
    return batch;
}

function budgetOf(instanceId: string): Budget {
    let budget = budgets.get(instanceId);
    if (budget === undefined) {
        budget = { windowStart: Date.now(), events: 0, widgetUpdates: 0, droppedEvents: 0, droppedEntries: new Map() };
        budgets.set(instanceId, budget);
    }
    return budget;
}

function bytesOf(data: ArrayBuffer | ArrayBufferView | number[]): Uint8Array {
    if (data instanceof ArrayBuffer) {
        return new Uint8Array(data);
    }
    if (ArrayBuffer.isView(data)) {
        return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    }
    return Uint8Array.from(data);
}

function joined(items: Batch["items"], size: number): ArrayBuffer {
    const all = new Uint8Array(size);
    let offset = 0;
    for (const { bytes } of items) {
        if (bytes !== null) {
            all.set(bytes, offset);
            offset += bytes.byteLength;
        }
    }
    return all.buffer;
}
