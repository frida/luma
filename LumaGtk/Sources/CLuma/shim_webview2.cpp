#include "include/CLuma.h"

#include <gtk/gtk.h>
#include <gdk/win32/gdkwin32.h>
#include <windows.h>
#include <wrl.h>
#include <WebView2.h>

#include <string>
#include <vector>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

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

} // namespace

struct LumaMonacoView {
    GtkWidget *placeholder = nullptr;
    HWND parent_hwnd = nullptr;

    ComPtr<ICoreWebView2Environment> env;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webview;
    EventRegistrationToken message_token{};
    EventRegistrationToken nav_token{};

    LumaMonacoLoadFinishedCallback load_callback = nullptr;
    void *load_user_data = nullptr;
    LumaMonacoTextCallback text_callback = nullptr;
    void *text_user_data = nullptr;

    std::wstring pending_uri;
    std::vector<std::wstring> pending_scripts;

    bool controller_ready = false;
    bool delivered_load_finished = false;
};

static void
sync_bounds(LumaMonacoView *self)
{
    if (!self->controller_ready) {
        return;
    }

    GtkNative *native = gtk_widget_get_native(self->placeholder);
    if (native == nullptr) {
        return;
    }

    graphene_point_t origin = GRAPHENE_POINT_INIT(0, 0);
    graphene_point_t root_pt;
    if (!gtk_widget_compute_point(self->placeholder, GTK_WIDGET(native), &origin, &root_pt)) {
        return;
    }

    int w = gtk_widget_get_width(self->placeholder);
    int h = gtk_widget_get_height(self->placeholder);
    if (w <= 0 || h <= 0) {
        self->controller->put_IsVisible(FALSE);
        return;
    }

    double surface_dx = 0, surface_dy = 0;
    gtk_native_get_surface_transform(native, &surface_dx, &surface_dy);

    RECT bounds;
    bounds.left = static_cast<LONG>(root_pt.x + surface_dx);
    bounds.top = static_cast<LONG>(root_pt.y + surface_dy);
    bounds.right = bounds.left + w;
    bounds.bottom = bounds.top + h;

    self->controller->put_Bounds(bounds);
    self->controller->put_IsVisible(TRUE);
}

static void
flush_pending(LumaMonacoView *self)
{
    if (!self->controller_ready) {
        return;
    }
    for (const auto &script : self->pending_scripts) {
        self->webview->ExecuteScript(script.c_str(), nullptr);
    }
    self->pending_scripts.clear();
    if (!self->pending_uri.empty()) {
        self->webview->Navigate(self->pending_uri.c_str());
        self->pending_uri.clear();
    }
}

static HRESULT
on_webview2_controller_created(LumaMonacoView *self,
                               HRESULT result,
                               ICoreWebView2Controller *raw_controller)
{
    if (FAILED(result) || raw_controller == nullptr) {
        return result;
    }
    self->controller = raw_controller;

    ComPtr<ICoreWebView2> wv;
    if (FAILED(self->controller->get_CoreWebView2(&wv))) {
        return E_FAIL;
    }
    self->webview = wv;

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
                if (self->text_callback) {
                    self->text_callback(text.c_str(), self->text_user_data);
                }
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
                    if (self->load_callback) {
                        self->load_callback(self, self->load_user_data);
                    }
                }
                return S_OK;
            }).Get(),
        &self->nav_token);

    self->controller_ready = true;
    sync_bounds(self);
    flush_pending(self);
    return S_OK;
}

static HRESULT
on_webview2_environment_created(LumaMonacoView *self,
                                HRESULT result,
                                ICoreWebView2Environment *raw_env)
{
    if (FAILED(result) || raw_env == nullptr || self->parent_hwnd == nullptr) {
        return result;
    }
    self->env = raw_env;
    return self->env->CreateCoreWebView2Controller(
        self->parent_hwnd,
        Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
            [self](HRESULT r, ICoreWebView2Controller *c) -> HRESULT {
                return on_webview2_controller_created(self, r, c);
            }).Get());
}

static void
start_webview2(LumaMonacoView *self)
{
    if (self->env) {
        return;
    }
    CreateCoreWebView2EnvironmentWithOptions(
        nullptr, nullptr, nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [self](HRESULT r, ICoreWebView2Environment *e) -> HRESULT {
                return on_webview2_environment_created(self, r, e);
            }).Get());
}

static void
on_placeholder_realize(GtkWidget *widget, gpointer user_data)
{
    LumaMonacoView *self = static_cast<LumaMonacoView *>(user_data);

    GtkNative *native = gtk_widget_get_native(widget);
    if (native == nullptr) {
        return;
    }
    GdkSurface *surface = gtk_native_get_surface(native);
    if (surface == nullptr || !GDK_IS_WIN32_SURFACE(surface)) {
        return;
    }
    self->parent_hwnd = reinterpret_cast<HWND>(
        gdk_win32_surface_get_handle(GDK_WIN32_SURFACE(surface)));
    start_webview2(self);
}

static void
on_placeholder_resize(GtkWidget *widget, int width, int height, gpointer user_data)
{
    (void)widget;
    (void)width;
    (void)height;
    sync_bounds(static_cast<LumaMonacoView *>(user_data));
}

static void
on_placeholder_unrealize(GtkWidget *widget, gpointer user_data)
{
    (void)widget;
    LumaMonacoView *self = static_cast<LumaMonacoView *>(user_data);
    if (self->controller) {
        self->controller->Close();
    }
    self->controller.Reset();
    self->webview.Reset();
    self->env.Reset();
    self->controller_ready = false;
    self->parent_hwnd = nullptr;
}

extern "C" {

LumaMonacoView *
luma_monaco_view_new(void)
{
    LumaMonacoView *self = new LumaMonacoView();
    self->placeholder = gtk_drawing_area_new();

    g_signal_connect(self->placeholder, "realize", G_CALLBACK(on_placeholder_realize), self);
    g_signal_connect(self->placeholder, "resize", G_CALLBACK(on_placeholder_resize), self);
    g_signal_connect(self->placeholder, "unrealize", G_CALLBACK(on_placeholder_unrealize), self);

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
    if (view->controller_ready) {
        view->webview->Navigate(wuri.c_str());
    } else {
        view->pending_uri = std::move(wuri);
    }
}

void
luma_monaco_view_evaluate(LumaMonacoView *view, const char *script_utf8)
{
    if (view == nullptr || script_utf8 == nullptr) {
        return;
    }
    std::wstring script = Utf8ToWide(script_utf8);
    if (view->controller_ready) {
        view->webview->ExecuteScript(script.c_str(), nullptr);
    } else {
        view->pending_scripts.push_back(std::move(script));
    }
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
