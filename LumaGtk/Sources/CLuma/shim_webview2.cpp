#include "include/CLuma.h"
#include "webview2_capture.h"

#include <gtk/gtk.h>
#include <gdk/win32/gdkwin32.h>
#include <windows.h>
#include <wrl.h>
#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;

namespace {

std::wstring Utf8ToWide(const char *utf8)
{
    if (utf8 == nullptr) {
        return std::wstring();
    }
    int needed = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    if (needed <= 0) {
        return std::wstring();
    }
    std::wstring result(static_cast<size_t>(needed - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, &result[0], needed);
    return result;
}

std::string WideToUtf8(LPCWSTR wide)
{
    if (wide == nullptr) {
        return std::string();
    }
    int needed = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
    if (needed <= 0) {
        return std::string();
    }
    std::string result(static_cast<size_t>(needed - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, &result[0], needed, nullptr, nullptr);
    return result;
}

// Forward Monaco's `window.webkit.messageHandlers.*.postMessage` onto
// WebView2's `window.chrome.webview.postMessage` so the editor's JS glue
// works unchanged across WebKit/WebKitGTK/WebView2.
constexpr wchar_t kBootstrapScript[] =
    L"(function(){"
    L"  if (window.webkit) return;"
    L"  const post = (name) => ({"
    L"    postMessage: (msg) => window.chrome.webview.postMessage({channel: name, data: msg})"
    L"  });"
    L"  window.webkit = {"
    L"    messageHandlers: {"
    L"      updateText: post('updateText'),"
    L"      topLevelSymbols: post('topLevelSymbols')"
    L"    }"
    L"  };"
    L"})();";

// Thread messages posted to the WebView2 worker's message loop.
constexpr UINT kMsgInvoke = WM_APP + 100;  // lParam is a heap std::function<void()>
constexpr UINT kMsgStop = WM_APP + 101;

const wchar_t kInputWindowClass[] = L"LumaMonacoWebViewInput";
constexpr int kOffScreen = -32000;

} // namespace

// The editor renders through WebView2 visual hosting into an off-screen
// composition visual, which LumaWebViewCapture mirrors to CPU frames drawn as an
// ordinary GdkTexture in a GtkPicture — so it composes with GTK popovers,
// dialogs and overlays at any z-order.
//
// WebView2 and its capture run on a dedicated STA worker thread with its own
// Win32 message pump, never on the GTK main thread: Windows.Graphics.Capture
// stops delivering frames for a window whose owning thread also hosts WebView2,
// so the editor's host window must live away from GTK's thread. The GTK main
// thread marshals commands to the worker (kMsgInvoke) and the worker marshals
// GTK-touching callbacks back with g_idle_add.
struct LumaMonacoView {
    GtkWidget *placeholder = nullptr;

    std::thread worker;
    std::mutex worker_mutex;
    DWORD worker_tid = 0;
    DWORD gtk_tid = 0;
    bool input_attached = false;
    std::vector<std::function<void()>> prestart;  // guarded by worker_mutex

    // Worker-thread-only WebView2 state.
    HWND input_hwnd = nullptr;
    ComPtr<ICoreWebView2Environment> env;
    ComPtr<ICoreWebView2CompositionController> comp_controller;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webview;
    EventRegistrationToken message_token{};
    EventRegistrationToken nav_token{};
    EventRegistrationToken cursor_token{};
    LumaWebViewCapture *capture = nullptr;
    std::wstring pending_uri;
    std::vector<std::wstring> pending_scripts;
    bool delivered_load_finished = false;

    std::atomic<bool> controller_ready{false};

    LumaMonacoLoadFinishedCallback load_callback = nullptr;
    void *load_user_data = nullptr;
    LumaMonacoTextCallback text_callback = nullptr;
    void *text_user_data = nullptr;

    // Owned by the GTK main thread.
    double scale = 1.0;
    double last_pointer_x = 0;
    double last_pointer_y = 0;
    int last_width = 0;
    int last_height = 0;

    // Latest captured frame, produced on a capture threadpool thread and drained
    // on the GTK main thread; frame_mutex guards the hand-off.
    std::mutex frame_mutex;
    std::vector<uint8_t> pending_frame;
    int pending_frame_width = 0;
    int pending_frame_height = 0;
    bool frame_dirty = false;
    bool idle_scheduled = false;
};

// --- cross-thread marshalling ----------------------------------------------

static gboolean
run_on_main_trampoline(gpointer user_data)
{
    auto *fn = static_cast<std::function<void()> *>(user_data);
    (*fn)();
    delete fn;
    return G_SOURCE_REMOVE;
}

// Runs `fn` on the GTK main thread. Safe to call from any thread (g_idle_add is
// thread-safe); used by worker-thread WebView2 callbacks that touch GTK.
static void
post_to_main(std::function<void()> fn)
{
    g_idle_add(run_on_main_trampoline, new std::function<void()>(std::move(fn)));
}

// Runs `fn` on the WebView2 worker thread. Calls made before the worker's
// message queue exists are queued and replayed once it does.
static void
post_to_worker(LumaMonacoView *self, std::function<void()> fn)
{
    std::lock_guard<std::mutex> lock(self->worker_mutex);
    if (self->worker_tid != 0) {
        PostThreadMessageW(self->worker_tid, kMsgInvoke, 0,
                           reinterpret_cast<LPARAM>(new std::function<void()>(std::move(fn))));
    } else {
        self->prestart.push_back(std::move(fn));
    }
}

static void sync_size(LumaMonacoView *self);

// --- captured-frame delivery (main thread) ---------------------------------

static gboolean
deliver_frame(gpointer user_data)
{
    LumaMonacoView *self = static_cast<LumaMonacoView *>(user_data);
    std::vector<uint8_t> frame;
    int w = 0, h = 0;
    {
        std::lock_guard<std::mutex> lock(self->frame_mutex);
        self->idle_scheduled = false;
        if (!self->frame_dirty) {
            return G_SOURCE_REMOVE;
        }
        frame = std::move(self->pending_frame);
        self->pending_frame.clear();
        w = self->pending_frame_width;
        h = self->pending_frame_height;
        self->frame_dirty = false;
    }
    if (w <= 0 || h <= 0 || frame.empty()) {
        return G_SOURCE_REMOVE;
    }

    GBytes *bytes = g_bytes_new(frame.data(), frame.size());
    GdkTexture *texture = gdk_memory_texture_new(w, h, GDK_MEMORY_B8G8R8A8_PREMULTIPLIED,
                                                 bytes, static_cast<gsize>(w) * 4);
    gtk_picture_set_paintable(GTK_PICTURE(self->placeholder), GDK_PAINTABLE(texture));
    g_object_unref(texture);
    g_bytes_unref(bytes);
    return G_SOURCE_REMOVE;
}

// Runs on a capture threadpool thread: pack the frame tightly and hand it to the
// main thread. Only the newest frame is kept; drawing happens in deliver_frame.
static void
on_capture_frame(LumaMonacoView *self, const uint8_t *bgra, int width, int height, int stride)
{
    if (width <= 0 || height <= 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(self->frame_mutex);
    self->pending_frame.resize(static_cast<size_t>(width) * height * 4);
    for (int row = 0; row < height; row++) {
        memcpy(self->pending_frame.data() + static_cast<size_t>(row) * width * 4,
               bgra + static_cast<size_t>(row) * stride,
               static_cast<size_t>(width) * 4);
    }
    self->pending_frame_width = width;
    self->pending_frame_height = height;
    self->frame_dirty = true;
    if (!self->idle_scheduled) {
        self->idle_scheduled = true;
        g_idle_add(deliver_frame, self);
    }
}

// --- cursor translation -----------------------------------------------------

// WebView2 requests a cursor by Win32 system-cursor id; GTK sets cursors by
// CSS name, so translate the common ones the editor uses.
static const char *
gtk_cursor_name_for_system_id(UINT32 id)
{
    switch (id) {
        case 32513: return "text";        // IDC_IBEAM
        case 32649: return "pointer";     // IDC_HAND
        case 32646: return "move";        // IDC_SIZEALL
        case 32644: return "ew-resize";   // IDC_SIZEWE
        case 32645: return "ns-resize";   // IDC_SIZENS
        case 32642: return "nwse-resize"; // IDC_SIZENWSE
        case 32643: return "nesw-resize"; // IDC_SIZENESW
        case 32648: return "not-allowed"; // IDC_NO
        case 32515: return "crosshair";   // IDC_CROSS
        case 32514: return "wait";        // IDC_WAIT
        case 32651: return "help";        // IDC_HELP
        default:    return "default";     // IDC_ARROW and the rest
    }
}

// --- WebView2 lifecycle (worker thread) ------------------------------------

static void
worker_flush_pending(LumaMonacoView *self)
{
    for (const auto &script : self->pending_scripts) {
        self->webview->ExecuteScript(script.c_str(), nullptr);
    }
    self->pending_scripts.clear();
    if (!self->pending_uri.empty()) {
        self->webview->Navigate(self->pending_uri.c_str());
    }
}

static HRESULT
worker_on_controller_created(LumaMonacoView *self, HRESULT result,
                             ICoreWebView2CompositionController *raw_controller)
{
    if (FAILED(result) || raw_controller == nullptr) {
        return result;
    }
    self->comp_controller = raw_controller;
    if (FAILED(self->comp_controller.As(&self->controller))) {
        return E_FAIL;
    }
    if (FAILED(self->controller->get_CoreWebView2(&self->webview))) {
        return E_FAIL;
    }

    self->capture = new LumaWebViewCapture();
    self->capture->on_frame = [self](const uint8_t *bgra, int fw, int fh, int stride) {
        on_capture_frame(self, bgra, fw, fh, stride);
    };
    if (!self->capture->start(800, 600)) {
        return E_FAIL;
    }
    self->comp_controller->put_RootVisualTarget(self->capture->root_visual());

    RECT bounds = { 0, 0, 800, 600 };
    self->controller->put_Bounds(bounds);
    self->controller->put_IsVisible(TRUE);

    self->comp_controller->add_CursorChanged(
        Callback<ICoreWebView2CursorChangedEventHandler>(
            [self](ICoreWebView2CompositionController *sender, IUnknown *) -> HRESULT {
                UINT32 cursor_id = 0;
                sender->get_SystemCursorId(&cursor_id);
                const char *name = gtk_cursor_name_for_system_id(cursor_id);
                post_to_main([self, name] {
                    gtk_widget_set_cursor_from_name(self->placeholder, name);
                });
                return S_OK;
            }).Get(),
        &self->cursor_token);

    self->webview->AddScriptToExecuteOnDocumentCreated(kBootstrapScript, nullptr);

    self->webview->add_WebMessageReceived(
        Callback<ICoreWebView2WebMessageReceivedEventHandler>(
            [self](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {
                LPWSTR json = nullptr;
                if (FAILED(args->get_WebMessageAsJson(&json)) || json == nullptr) {
                    return S_OK;
                }
                std::string payload = WideToUtf8(json);
                CoTaskMemFree(json);

                auto channel_pos = payload.find("\"channel\"");
                auto data_pos = payload.find("\"data\"");
                if (channel_pos == std::string::npos || data_pos == std::string::npos) {
                    return S_OK;
                }
                if (payload.find("\"updateText\"", channel_pos) == std::string::npos) {
                    return S_OK;
                }
                auto value_start = payload.find('"', payload.find(':', data_pos) + 1);
                if (value_start == std::string::npos) {
                    return S_OK;
                }
                auto value_end = payload.find('"', value_start + 1);
                if (value_end == std::string::npos) {
                    return S_OK;
                }
                std::string text = payload.substr(value_start + 1, value_end - value_start - 1);
                post_to_main([self, text] {
                    if (self->text_callback) {
                        self->text_callback(text.c_str(), self->text_user_data);
                    }
                });
                return S_OK;
            }).Get(),
        &self->message_token);

    self->webview->add_NavigationCompleted(
        Callback<ICoreWebView2NavigationCompletedEventHandler>(
            [self](ICoreWebView2 *, ICoreWebView2NavigationCompletedEventArgs *args) -> HRESULT {
                BOOL success = FALSE;
                args->get_IsSuccess(&success);
                if (success && !self->delivered_load_finished) {
                    self->delivered_load_finished = true;
                    post_to_main([self] {
                        if (self->load_callback) {
                            self->load_callback(self, self->load_user_data);
                        }
                    });
                }
                return S_OK;
            }).Get(),
        &self->nav_token);

    self->controller_ready.store(true);
    worker_flush_pending(self);
    post_to_main([self] { sync_size(self); });
    return S_OK;
}

static void
worker_start_webview2(LumaMonacoView *self)
{
    // Off-screen input window: WebView2's composition host is captured from its
    // DComp visual, so this window is never shown; it only anchors the webview.
    self->input_hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, kInputWindowClass, L"", WS_POPUP,
                                       kOffScreen, kOffScreen, 800, 600,
                                       nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);

    // We render off-screen; Chromium's native window occlusion detection would
    // see the host window as hidden and throttle rendering to a stop, so disable
    // it or no frames are ever produced.
    ComPtr<ICoreWebView2EnvironmentOptions> options = Make<CoreWebView2EnvironmentOptions>();
    options->put_AdditionalBrowserArguments(L"--disable-features=CalculateNativeWinOcclusion");
    CreateCoreWebView2EnvironmentWithOptions(
        nullptr, nullptr, options.Get(),
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [self](HRESULT r, ICoreWebView2Environment *env) -> HRESULT {
                if (FAILED(r) || env == nullptr) {
                    return r;
                }
                self->env = env;
                ComPtr<ICoreWebView2Environment3> env3;
                if (FAILED(self->env.As(&env3))) {
                    return E_FAIL;
                }
                return env3->CreateCoreWebView2CompositionController(
                    self->input_hwnd,
                    Callback<ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler>(
                        [self](HRESULT r2, ICoreWebView2CompositionController *c) -> HRESULT {
                            return worker_on_controller_created(self, r2, c);
                        }).Get());
            }).Get());
}

static void
worker_teardown(LumaMonacoView *self)
{
    if (self->capture) {
        self->capture->on_frame = nullptr;
        self->capture->stop();
        delete self->capture;
        self->capture = nullptr;
    }
    if (self->controller) {
        self->controller->Close();
    }
    self->comp_controller.Reset();
    self->controller.Reset();
    self->webview.Reset();
    self->env.Reset();
    if (self->input_hwnd) {
        DestroyWindow(self->input_hwnd);
        self->input_hwnd = nullptr;
    }
}

static void
webview_worker_main(LumaMonacoView *self)
{
    OleInitialize(nullptr);

    WNDCLASSEXW wc = { sizeof(wc) };
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kInputWindowClass;
    RegisterClassExW(&wc);

    MSG probe;
    PeekMessageW(&probe, nullptr, WM_USER, WM_USER, PM_NOREMOVE);  // force the queue to exist
    {
        std::lock_guard<std::mutex> lock(self->worker_mutex);
        self->worker_tid = GetCurrentThreadId();
        for (auto &fn : self->prestart) {
            PostThreadMessageW(self->worker_tid, kMsgInvoke, 0,
                               reinterpret_cast<LPARAM>(new std::function<void()>(std::move(fn))));
        }
        self->prestart.clear();
    }

    worker_start_webview2(self);

    // WebView2 renders into the capture's visual asynchronously; committing the
    // composition device on a timer presents those updates so the capture sees
    // them.
    UINT_PTR commit_timer = SetTimer(nullptr, 0, 16, nullptr);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (msg.hwnd == nullptr && msg.message == kMsgInvoke) {
            auto *fn = reinterpret_cast<std::function<void()> *>(msg.lParam);
            (*fn)();
            delete fn;
            continue;
        }
        if (msg.hwnd == nullptr && msg.message == kMsgStop) {
            break;
        }
        if (msg.hwnd == nullptr && msg.message == WM_TIMER) {
            if (self->capture) {
                self->capture->commit();
            }
            continue;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    KillTimer(nullptr, commit_timer);
    worker_teardown(self);
    OleUninitialize();
}

// --- sizing (main thread → worker) -----------------------------------------

static double
surface_scale_for(LumaMonacoView *self)
{
    GtkNative *native = gtk_widget_get_native(self->placeholder);
    GdkSurface *surface = (native != nullptr) ? gtk_native_get_surface(native) : nullptr;
    double scale = (surface != nullptr) ? gdk_surface_get_scale(surface) : 1.0;
    return scale < 1.0 ? 1.0 : scale;
}

// Size the off-screen webview (and its capture target) to the widget's current
// device-pixel extent so the texture maps 1:1 onto the GtkPicture.
static void
sync_size(LumaMonacoView *self)
{
    if (!self->controller_ready.load()) {
        return;
    }
    int w = gtk_widget_get_width(self->placeholder);
    int h = gtk_widget_get_height(self->placeholder);
    if (w <= 0 || h <= 0) {
        return;
    }
    self->scale = surface_scale_for(self);
    unsigned int pixel_w = static_cast<unsigned int>(w * self->scale);
    unsigned int pixel_h = static_cast<unsigned int>(h * self->scale);
    double scale = self->scale;

    post_to_worker(self, [self, pixel_w, pixel_h, scale] {
        if (!self->controller) {
            return;
        }
        RECT bounds = { 0, 0, static_cast<LONG>(pixel_w), static_cast<LONG>(pixel_h) };
        self->controller->put_Bounds(bounds);
        ComPtr<ICoreWebView2Controller3> controller3;
        if (SUCCEEDED(self->controller.As(&controller3))) {
            controller3->put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS);
            controller3->put_RasterizationScale(scale);
        }
        self->controller->put_IsVisible(TRUE);
        self->capture->resize(pixel_w, pixel_h);
    });
}

// --- GTK widget callbacks (main thread) ------------------------------------

static gboolean
on_placeholder_tick(GtkWidget *widget, GdkFrameClock *clock, gpointer user_data)
{
    (void)clock;
    LumaMonacoView *self = static_cast<LumaMonacoView *>(user_data);
    int w = gtk_widget_get_width(widget);
    int h = gtk_widget_get_height(widget);
    if (w != self->last_width || h != self->last_height) {
        self->last_width = w;
        self->last_height = h;
        sync_size(self);
    }
    return G_SOURCE_CONTINUE;
}

static void
on_placeholder_destroy(GtkWidget *widget, gpointer user_data)
{
    (void)widget;
    LumaMonacoView *self = static_cast<LumaMonacoView *>(user_data);
    DWORD tid;
    {
        std::lock_guard<std::mutex> lock(self->worker_mutex);
        tid = self->worker_tid;
    }
    if (tid != 0) {
        PostThreadMessageW(tid, kMsgStop, 0, 0);
    }
    if (self->worker.joinable()) {
        self->worker.join();
    }
}

// --- input forwarding (main thread → worker) -------------------------------

// WebView2 visual hosting receives no OS input, so GTK event controllers on the
// placeholder forward pointer and scroll events into the webview via the
// composition controller (on the worker thread). Points are in the webview's
// client space: the placeholder-local position scaled to device pixels.

// WebView2 (on the worker thread) reads keyboard from the focus window of its
// input queue. While the editor holds GTK focus, merge the GTK and worker input
// queues (AttachThreadInput) and make the worker's input window the focus
// window, so keystrokes physically delivered to the active GTK window route to
// the worker thread where WebView2 consumes them.
static void
on_focus_enter(GtkEventControllerFocus *controller, gpointer user_data)
{
    (void)controller;
    LumaMonacoView *self = static_cast<LumaMonacoView *>(user_data);
    DWORD wtid;
    {
        std::lock_guard<std::mutex> lock(self->worker_mutex);
        wtid = self->worker_tid;
    }
    if (wtid == 0 || self->input_attached) {
        return;
    }
    self->input_attached = AttachThreadInput(self->gtk_tid, wtid, TRUE);
    post_to_worker(self, [self] {
        if (self->input_hwnd) {
            SetFocus(self->input_hwnd);
        }
        if (self->controller) {
            self->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
        }
    });
}

static void
on_focus_leave(GtkEventControllerFocus *controller, gpointer user_data)
{
    (void)controller;
    LumaMonacoView *self = static_cast<LumaMonacoView *>(user_data);
    if (!self->input_attached) {
        return;
    }
    DWORD wtid;
    {
        std::lock_guard<std::mutex> lock(self->worker_mutex);
        wtid = self->worker_tid;
    }
    if (wtid != 0) {
        AttachThreadInput(self->gtk_tid, wtid, FALSE);
    }
    self->input_attached = false;
}

static COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS
mouse_virtual_keys(GdkModifierType state)
{
    unsigned int keys = COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_NONE;
    if (state & GDK_CONTROL_MASK) keys |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_CONTROL;
    if (state & GDK_SHIFT_MASK) keys |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_SHIFT;
    if (state & GDK_BUTTON1_MASK) keys |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_LEFT_BUTTON;
    if (state & GDK_BUTTON2_MASK) keys |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_MIDDLE_BUTTON;
    if (state & GDK_BUTTON3_MASK) keys |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_RIGHT_BUTTON;
    return static_cast<COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS>(keys);
}

static void
send_mouse(LumaMonacoView *self, COREWEBVIEW2_MOUSE_EVENT_KIND kind,
           GdkModifierType state, UINT32 mouse_data, double x, double y)
{
    if (!self->controller_ready.load()) {
        return;
    }
    POINT point = {
        static_cast<LONG>(x * self->scale),
        static_cast<LONG>(y * self->scale),
    };
    COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS keys = mouse_virtual_keys(state);
    post_to_worker(self, [self, kind, keys, mouse_data, point] {
        if (self->comp_controller) {
            self->comp_controller->SendMouseInput(kind, keys, mouse_data, point);
        }
    });
}

static void
on_pointer_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data)
{
    LumaMonacoView *self = static_cast<LumaMonacoView *>(user_data);
    self->last_pointer_x = x;
    self->last_pointer_y = y;
    GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller));
    send_mouse(self, COREWEBVIEW2_MOUSE_EVENT_KIND_MOVE, state, 0, x, y);
}

static void
on_pointer_leave(GtkEventControllerMotion *controller, gpointer user_data)
{
    (void)controller;
    LumaMonacoView *self = static_cast<LumaMonacoView *>(user_data);
    if (!self->controller_ready.load()) {
        return;
    }
    post_to_worker(self, [self] {
        if (self->comp_controller) {
            POINT point = { 0, 0 };
            self->comp_controller->SendMouseInput(COREWEBVIEW2_MOUSE_EVENT_KIND_LEAVE,
                                                  COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_NONE, 0, point);
        }
    });
}

static COREWEBVIEW2_MOUSE_EVENT_KIND
button_event_kind(guint button, bool down)
{
    switch (button) {
        case 2:  return down ? COREWEBVIEW2_MOUSE_EVENT_KIND_MIDDLE_BUTTON_DOWN
                             : COREWEBVIEW2_MOUSE_EVENT_KIND_MIDDLE_BUTTON_UP;
        case 3:  return down ? COREWEBVIEW2_MOUSE_EVENT_KIND_RIGHT_BUTTON_DOWN
                             : COREWEBVIEW2_MOUSE_EVENT_KIND_RIGHT_BUTTON_UP;
        default: return down ? COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_DOWN
                             : COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_UP;
    }
}

static void
on_click_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data)
{
    (void)n_press;
    LumaMonacoView *self = static_cast<LumaMonacoView *>(user_data);
    gtk_widget_grab_focus(self->placeholder);
    guint button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
    GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture));
    if (self->controller_ready.load()) {
        post_to_worker(self, [self] {
            if (self->controller) {
                self->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
            }
        });
    }
    send_mouse(self, button_event_kind(button, true), state, 0, x, y);
}

static void
on_click_released(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data)
{
    (void)n_press;
    guint button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
    GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture));
    send_mouse(static_cast<LumaMonacoView *>(user_data), button_event_kind(button, false), state, 0, x, y);
}

static gboolean
on_scroll(GtkEventControllerScroll *controller, double dx, double dy, gpointer user_data)
{
    LumaMonacoView *self = static_cast<LumaMonacoView *>(user_data);
    if (!self->controller_ready.load()) {
        return FALSE;
    }
    GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller));
    // GTK deltas are notches, positive down/right; WebView2 wants WHEEL_DELTA
    // units, positive up for the vertical wheel.
    if (dy != 0) {
        UINT32 delta = static_cast<UINT32>(static_cast<int>(-dy * WHEEL_DELTA));
        send_mouse(self, COREWEBVIEW2_MOUSE_EVENT_KIND_WHEEL, state, delta,
                   self->last_pointer_x, self->last_pointer_y);
    }
    if (dx != 0) {
        UINT32 delta = static_cast<UINT32>(static_cast<int>(dx * WHEEL_DELTA));
        send_mouse(self, COREWEBVIEW2_MOUSE_EVENT_KIND_HORIZONTAL_WHEEL, state, delta,
                   self->last_pointer_x, self->last_pointer_y);
    }
    return TRUE;
}

static void
install_input_controllers(LumaMonacoView *self)
{
    gtk_widget_set_focusable(self->placeholder, TRUE);

    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_pointer_motion), self);
    g_signal_connect(motion, "leave", G_CALLBACK(on_pointer_leave), self);
    gtk_widget_add_controller(self->placeholder, motion);

    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    g_signal_connect(click, "pressed", G_CALLBACK(on_click_pressed), self);
    g_signal_connect(click, "released", G_CALLBACK(on_click_released), self);
    gtk_widget_add_controller(self->placeholder, GTK_EVENT_CONTROLLER(click));

    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_scroll), self);
    gtk_widget_add_controller(self->placeholder, scroll);

    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(on_focus_enter), self);
    g_signal_connect(focus, "leave", G_CALLBACK(on_focus_leave), self);
    gtk_widget_add_controller(self->placeholder, focus);
}

extern "C" {

LumaMonacoView *
luma_monaco_view_new(void)
{
    LumaMonacoView *self = new LumaMonacoView();
    self->gtk_tid = GetCurrentThreadId();
    self->placeholder = gtk_picture_new();
    gtk_picture_set_content_fit(GTK_PICTURE(self->placeholder), GTK_CONTENT_FIT_FILL);
    gtk_widget_set_hexpand(self->placeholder, TRUE);
    gtk_widget_set_vexpand(self->placeholder, TRUE);

    g_signal_connect(self->placeholder, "destroy", G_CALLBACK(on_placeholder_destroy), self);
    gtk_widget_add_tick_callback(self->placeholder, on_placeholder_tick, self, nullptr);
    install_input_controllers(self);

    self->worker = std::thread([self] { webview_worker_main(self); });
    return self;
}

void *
luma_monaco_view_widget(LumaMonacoView *view)
{
    return view ? view->placeholder : nullptr;
}

void
luma_monaco_view_load_uri(LumaMonacoView *view, const char *uri)
{
    if (view == nullptr || uri == nullptr) {
        return;
    }
    std::wstring wuri = Utf8ToWide(uri);
    post_to_worker(view, [view, wuri] {
        view->pending_uri = wuri;
        if (view->controller_ready.load()) {
            view->webview->Navigate(view->pending_uri.c_str());
        }
    });
}

void
luma_monaco_view_grab_focus(LumaMonacoView *view)
{
    if (view == nullptr) {
        return;
    }
    post_to_worker(view, [view] {
        if (view->controller) {
            view->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
        }
    });
}

void
luma_monaco_view_evaluate(LumaMonacoView *view, const char *script_utf8)
{
    if (view == nullptr || script_utf8 == nullptr) {
        return;
    }
    std::wstring script = Utf8ToWide(script_utf8);
    post_to_worker(view, [view, script] {
        if (view->controller_ready.load()) {
            view->webview->ExecuteScript(script.c_str(), nullptr);
        } else {
            view->pending_scripts.push_back(script);
        }
    });
}

void
luma_monaco_view_set_load_finished(LumaMonacoView *view,
                                    LumaMonacoLoadFinishedCallback callback,
                                    void *user_data)
{
    if (view == nullptr) {
        return;
    }
    view->load_callback = callback;
    view->load_user_data = user_data;
}

void
luma_monaco_view_set_text_handler(LumaMonacoView *view,
                                   LumaMonacoTextCallback callback,
                                   void *user_data)
{
    if (view == nullptr) {
        return;
    }
    view->text_callback = callback;
    view->text_user_data = user_data;
}

} // extern "C"
