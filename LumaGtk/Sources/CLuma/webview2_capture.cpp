// WebView2 composition-visual capture for the LumaGtk Windows shim.
//
// Approach A (capture-to-texture): the webview renders into a DirectComposition
// visual which we host on a hidden, off-screen top-level window; DWM composites
// that window, and Windows.Graphics.Capture streams its pixels back to us as
// CPU BGRA buffers. GTK then draws those pixels as ordinary widget content, so
// the editor participates in normal GTK z-ordering (no airspace / occlusion).
//
// Why an off-screen window (rather than capturing the visual directly):
//   * WebView2's RootVisualTarget is a DirectComposition IDCompositionVisual.
//     GraphicsCaptureItem.CreateFromVisual only takes a Windows.UI.Composition
//     Visual, and such a free-floating tree is not composited in this process
//     (nothing dispatches the Compositor), so it has no capturable content.
//   * An IDCompositionVisual hosted in a target for a real (shown) window IS
//     composited by DWM regardless of the window's on-screen position, so it
//     has capturable content. We capture that window via
//     IGraphicsCaptureItemInterop::CreateForWindow.
//   * The window is positioned far off-screen and never activated, but NOT
//     cloaked (DWMWA_CLOAK) — cloaked windows are excluded from composition.
//   * WebView2 must be told not to throttle rendering when it thinks its window
//     is occluded (it is, being off-screen); the shim disables Chromium's native
//     window occlusion feature or no content is ever produced to capture.
//
// Threading: the D3D11 device, the DirectComposition device/target/root visual,
// and the capture pipeline are all built on the caller's thread — the GTK main
// thread, which also owns WebView2's composition controller. DirectComposition
// objects are single-threaded and WebView2 targets root_visual() from that same
// thread, so nothing crosses threads. The frame pool is free-threaded, so
// FrameArrived is delivered on a threadpool thread with no message pump needed;
// on_frame_arrived's D3D Map/Copy and the on_frame callback are serialized by
// mutex_.
//
// Link libraries (pulled in via #pragma comment below, honoured by clang-cl and
// MSVC): runtimeobject.lib, windowsapp.lib, d3d11.lib, dxgi.lib, dcomp.lib.

#include "webview2_capture.h"

#include <windows.h>
#include <cstdint>
#include <functional>
#include <mutex>

#include <wrl.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>

#include <d3d11.h>
#include <dxgi1_2.h>
#include <dcomp.h>

#include <roapi.h>
#include <windows.foundation.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#pragma comment(lib, "runtimeobject.lib")
#pragma comment(lib, "windowsapp.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dcomp.lib")

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;

namespace wf = ABI::Windows::Foundation;
namespace wg = ABI::Windows::Graphics;
namespace wgc = ABI::Windows::Graphics::Capture;
namespace wgdx = ABI::Windows::Graphics::DirectX;
namespace wgd3d = ABI::Windows::Graphics::DirectX::Direct3D11;

namespace {

// A free-threaded framepool requires its FrameArrived handler to be agile
// (IAgileObject); a plain WRL::Callback delegate is not, so add_FrameArrived
// fails with RO_E_MUST_BE_AGILE. FtmBase gives the handler the free-threaded
// marshaler, satisfying that.
class FrameArrivedHandler
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          wf::ITypedEventHandler<wgc::Direct3D11CaptureFramePool *, IInspectable *>,
          Microsoft::WRL::FtmBase> {
public:
    explicit FrameArrivedHandler(std::function<void(wgc::IDirect3D11CaptureFramePool *)> callback)
        : callback_(std::move(callback)) {}

    HRESULT STDMETHODCALLTYPE Invoke(wgc::IDirect3D11CaptureFramePool *pool, IInspectable *) override
    {
        callback_(pool);
        return S_OK;
    }

private:
    std::function<void(wgc::IDirect3D11CaptureFramePool *)> callback_;
};

const wchar_t kHostWindowClass[] = L"LumaWebViewCaptureHost";

ATOM
ensure_host_window_class()
{
    static ATOM atom = 0;
    if (atom != 0) {
        return atom;
    }
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kHostWindowClass;
    atom = RegisterClassExW(&wc);
    return atom;
}



} // namespace

class LumaWebViewCaptureImpl {
public:
    explicit LumaWebViewCaptureImpl(LumaWebViewCapture *owner) : owner_(owner) {}

    ~LumaWebViewCaptureImpl() { stop(); }

    bool start(unsigned int width, unsigned int height)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (started_) {
            return true;
        }
        width_ = width ? width : 1;
        height_ = height ? height : 1;

        // The DComp device, host window, and root visual must live on this
        // thread — the caller's thread, which also owns WebView2's composition
        // controller — since DirectComposition objects are single-threaded and
        // WebView2 targets the visual from the same thread. The frame pool is
        // free-threaded, so FrameArrived is delivered on a threadpool thread with
        // no message pump here.
        if (!create_d3d_device() || !create_composition() || !create_capture()) {
            teardown_all_locked();
            if (host_hwnd_) {
                DestroyWindow(host_hwnd_);
                host_hwnd_ = nullptr;
            }
            return false;
        }
        started_ = true;
        return true;
    }

    IUnknown *root_visual() const { return webview_visual_.Get(); }

    // WebView2 renders into webview_visual_ asynchronously; DirectComposition
    // only presents those updates to DWM (and thus to the capture) after a
    // Commit. The caller drives this from its frame clock.
    void commit()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (started_ && dcomp_device_) {
            dcomp_device_->Commit();
        }
    }

    void resize(unsigned int width, unsigned int height)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!started_) {
            return;
        }
        width_ = width ? width : 1;
        height_ = height ? height : 1;
        SetWindowPos(host_hwnd_, nullptr, kOffScreen, kOffScreen,
                     static_cast<int>(width_), static_cast<int>(height_),
                     SWP_NOZORDER | SWP_NOACTIVATE);
        // Recreate() resizes the existing pool in place, keeping the capture
        // session and FrameArrived subscription alive; swapping in a fresh pool
        // would orphan the session (which stays bound to the old pool) and stop
        // frame delivery.
        if (frame_pool_ && rt_device_) {
            wg::SizeInt32 size = { static_cast<INT32>(width_), static_cast<INT32>(height_) };
            frame_pool_->Recreate(rt_device_.Get(), wgdx::DirectXPixelFormat_B8G8R8A8UIntNormalized, 2, size);
        }
    }

    void stop()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!started_) {
            return;
        }
        teardown_all_locked();
        if (host_hwnd_) {
            DestroyWindow(host_hwnd_);
            host_hwnd_ = nullptr;
        }
        started_ = false;
    }

private:
    static const int kOffScreen = -32000;

    bool create_d3d_device()
    {
        UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;

        // Windows.Graphics.Capture only delivers frames if the capture device is
        // on the same adapter DWM composites on. Pick the first hardware adapter
        // that actually drives a display output rather than trusting the default
        // adapter (which can be a render-only / basic device -> silent no frames).
        ComPtr<IDXGIFactory1> factory;
        if (SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void **>(factory.GetAddressOf())))) {
            ComPtr<IDXGIAdapter1> adapter;
            for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; i++) {
                DXGI_ADAPTER_DESC1 desc = {};
                adapter->GetDesc1(&desc);
                ComPtr<IDXGIOutput> output;
                bool has_output = SUCCEEDED(adapter->EnumOutputs(0, &output)) && output;
                if (has_output && (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) == 0) {
                    HRESULT hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, flags,
                                                   nullptr, 0, D3D11_SDK_VERSION,
                                                   &d3d_device_, nullptr, &d3d_context_);
                    if (SUCCEEDED(hr)) {
                        return true;
                    }
                }
                adapter.Reset();
            }
        }

        HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                                       nullptr, 0, D3D11_SDK_VERSION,
                                       &d3d_device_, nullptr, &d3d_context_);
        return SUCCEEDED(hr) && d3d_device_ && d3d_context_;
    }

    // WebView2's put_RootVisualTarget takes an IDCompositionVisual, so the editor
    // renders into a DirectComposition visual hosted on a hidden off-screen
    // window. DWM composites that window regardless of on-screen position, so
    // Windows.Graphics.Capture (CreateForWindow) can stream its pixels back —
    // nothing is ever shown, so there is nothing for GTK overlays to occlude.
    bool create_composition()
    {
        ComPtr<IDXGIDevice> dxgi_device;
        if (FAILED(d3d_device_.As(&dxgi_device))) {
            return false;
        }
        if (FAILED(DCompositionCreateDevice(dxgi_device.Get(), __uuidof(IDCompositionDevice),
                                            reinterpret_cast<void **>(dcomp_device_.GetAddressOf())))) {
            return false;
        }
        if (ensure_host_window_class() == 0) {
            return false;
        }
        host_hwnd_ = CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP | WS_EX_TOOLWINDOW,
                                     kHostWindowClass, L"", WS_POPUP,
                                     kOffScreen, kOffScreen,
                                     static_cast<int>(width_), static_cast<int>(height_),
                                     nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
        if (host_hwnd_ == nullptr) {
            return false;
        }
        ShowWindow(host_hwnd_, SW_SHOWNOACTIVATE);

        // WebView2 takes over the visual handed to put_RootVisualTarget, so give
        // it a child and keep our own visual as the window's stable root — that
        // root is what DWM composites and what CreateForWindow captures.
        if (FAILED(dcomp_device_->CreateTargetForHwnd(host_hwnd_, TRUE, &dcomp_target_)) ||
            FAILED(dcomp_device_->CreateVisual(&root_visual_)) ||
            FAILED(dcomp_device_->CreateVisual(&webview_visual_)) ||
            FAILED(dcomp_target_->SetRoot(root_visual_.Get())) ||
            FAILED(root_visual_->AddVisual(webview_visual_.Get(), TRUE, nullptr))) {
            return false;
        }
        return SUCCEEDED(dcomp_device_->Commit());
    }

    // Caller holds mutex_.
    bool create_capture()
    {
        ComPtr<IDXGIDevice> dxgi_device;
        if (FAILED(d3d_device_.As(&dxgi_device))) {
            return false;
        }
        ComPtr<IInspectable> inspectable;
        HRESULT hr = CreateDirect3D11DeviceFromDXGIDevice(dxgi_device.Get(), &inspectable);
        if (FAILED(hr)) {
            return false;
        }
        if (FAILED(inspectable.As(&rt_device_))) {
            return false;
        }

        ComPtr<IGraphicsCaptureItemInterop> interop;
        hr = RoGetActivationFactory(
                HStringReference(RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureItem).Get(),
                __uuidof(IGraphicsCaptureItemInterop),
                reinterpret_cast<void **>(interop.GetAddressOf()));
        if (FAILED(hr)) {
            return false;
        }
        hr = interop->CreateForWindow(host_hwnd_, __uuidof(wgc::IGraphicsCaptureItem),
                                      reinterpret_cast<void **>(capture_item_.GetAddressOf()));
        if (FAILED(hr)) {
            return false;
        }

        hr = RoGetActivationFactory(
                HStringReference(RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool).Get(),
                __uuidof(wgc::IDirect3D11CaptureFramePoolStatics2),
                reinterpret_cast<void **>(frame_pool_statics_.GetAddressOf()));
        if (FAILED(hr)) {
            return false;
        }

        if (!recreate_frame_pool_locked()) {
            return false;
        }

        hr = frame_pool_->CreateCaptureSession(capture_item_.Get(), &session_);
        if (FAILED(hr)) {
            return false;
        }

        // Best-effort: hide the capture border and cursor (newer OS builds only).
        ComPtr<wgc::IGraphicsCaptureSession3> session3;
        if (SUCCEEDED(session_.As(&session3))) {
            session3->put_IsBorderRequired(false);
        }
        ComPtr<wgc::IGraphicsCaptureSession2> session2;
        if (SUCCEEDED(session_.As(&session2))) {
            session2->put_IsCursorCaptureEnabled(false);
        }

        HRESULT hr_sc = session_->StartCapture();
        return SUCCEEDED(hr_sc);
    }

    // Caller holds mutex_.
    bool recreate_frame_pool_locked()
    {
        if (!frame_pool_statics_ || !rt_device_) {
            return false;
        }

        if (frame_pool_ && frame_token_.value != 0) {
            frame_pool_->remove_FrameArrived(frame_token_);
            frame_token_.value = 0;
        }

        wg::SizeInt32 size = { static_cast<INT32>(width_), static_cast<INT32>(height_) };
        ComPtr<wgc::IDirect3D11CaptureFramePool> pool;
        // CreateFreeThreaded: FrameArrived is delivered on a threadpool thread,
        // so no thread here has to pump a DispatcherQueue for it.
        HRESULT hr = frame_pool_statics_->CreateFreeThreaded(
            rt_device_.Get(),
            wgdx::DirectXPixelFormat_B8G8R8A8UIntNormalized,
            2, size, &pool);
        if (FAILED(hr) || !pool) {
            return false;
        }
        frame_pool_ = pool;

        auto handler = Microsoft::WRL::Make<FrameArrivedHandler>(
            [this](wgc::IDirect3D11CaptureFramePool *pool) { on_frame_arrived(pool); });
        HRESULT hr_add = frame_pool_->add_FrameArrived(handler.Get(), &frame_token_);
        return SUCCEEDED(hr_add);
    }

    // Runs on the capture threadpool thread.
    void on_frame_arrived(wgc::IDirect3D11CaptureFramePool *pool)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!pool) {
            return;
        }

        ComPtr<wgc::IDirect3D11CaptureFrame> frame;
        HRESULT hr_next = pool->TryGetNextFrame(&frame);
        if (FAILED(hr_next) || !frame) {
            return;
        }

        wg::SizeInt32 content_size = {};
        frame->get_ContentSize(&content_size);
        if (content_size.Width > 0 && content_size.Height > 0 &&
            (content_size.Width != static_cast<INT32>(width_) ||
             content_size.Height != static_cast<INT32>(height_))) {
            width_ = static_cast<unsigned int>(content_size.Width);
            height_ = static_cast<unsigned int>(content_size.Height);
            wg::SizeInt32 size = { content_size.Width, content_size.Height };
            frame_pool_->Recreate(rt_device_.Get(), wgdx::DirectXPixelFormat_B8G8R8A8UIntNormalized, 2, size);
            // The just-dequeued frame is still the old size; present it anyway.
        }

        ComPtr<wgd3d::IDirect3DSurface> surface;
        if (FAILED(frame->get_Surface(&surface)) || !surface) {
            return;
        }
        ComPtr<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> access;
        if (FAILED(surface.As(&access))) {
            return;
        }
        ComPtr<ID3D11Texture2D> texture;
        if (FAILED(access->GetInterface(__uuidof(ID3D11Texture2D),
                                        reinterpret_cast<void **>(texture.GetAddressOf())))) {
            return;
        }

        D3D11_TEXTURE2D_DESC desc = {};
        texture->GetDesc(&desc);
        if (!ensure_staging_locked(desc.Width, desc.Height)) {
            return;
        }

        d3d_context_->CopyResource(staging_.Get(), texture.Get());

        D3D11_MAPPED_SUBRESOURCE mapped = {};
        if (FAILED(d3d_context_->Map(staging_.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
            return;
        }
        if (owner_->on_frame) {
            owner_->on_frame(static_cast<const uint8_t *>(mapped.pData),
                             static_cast<int>(desc.Width), static_cast<int>(desc.Height),
                             static_cast<int>(mapped.RowPitch));
        }
        d3d_context_->Unmap(staging_.Get(), 0);
    }

    // Caller holds mutex_.
    bool ensure_staging_locked(UINT width, UINT height)
    {
        if (staging_ && staging_w_ == width && staging_h_ == height) {
            return true;
        }
        staging_.Reset();
        D3D11_TEXTURE2D_DESC desc = {};
        desc.Width = width;
        desc.Height = height;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        if (FAILED(d3d_device_->CreateTexture2D(&desc, nullptr, &staging_))) {
            return false;
        }
        staging_w_ = width;
        staging_h_ = height;
        return true;
    }

    // Caller holds mutex_. Runs on the worker thread as it exits, which owns the
    // DComp device, host window, and capture objects.
    void teardown_all_locked()
    {
        if (frame_pool_ && frame_token_.value != 0) {
            frame_pool_->remove_FrameArrived(frame_token_);
            frame_token_.value = 0;
        }
        close_closable(session_);
        close_closable(frame_pool_);
        session_.Reset();
        frame_pool_.Reset();
        frame_pool_statics_.Reset();
        capture_item_.Reset();
        rt_device_.Reset();
        staging_.Reset();
        webview_visual_.Reset();
        root_visual_.Reset();
        dcomp_target_.Reset();
        if (dcomp_device_) {
            dcomp_device_->Commit();
        }
        dcomp_device_.Reset();
        d3d_context_.Reset();
        d3d_device_.Reset();
    }

    template <typename T>
    static void close_closable(const ComPtr<T> &obj)
    {
        if (!obj) {
            return;
        }
        ComPtr<wf::IClosable> closable;
        if (SUCCEEDED(obj.As(&closable))) {
            closable->Close();
        }
    }

    LumaWebViewCapture *owner_;
    std::mutex mutex_;
    bool started_ = false;
    unsigned int width_ = 1;
    unsigned int height_ = 1;

    HWND host_hwnd_ = nullptr;

    ComPtr<ID3D11Device> d3d_device_;
    ComPtr<ID3D11DeviceContext> d3d_context_;
    ComPtr<IDCompositionDevice> dcomp_device_;
    ComPtr<IDCompositionTarget> dcomp_target_;
    ComPtr<IDCompositionVisual> root_visual_;
    ComPtr<IDCompositionVisual> webview_visual_;

    ComPtr<wgd3d::IDirect3DDevice> rt_device_;
    ComPtr<wgc::IGraphicsCaptureItem> capture_item_;
    ComPtr<wgc::IDirect3D11CaptureFramePoolStatics2> frame_pool_statics_;
    ComPtr<wgc::IDirect3D11CaptureFramePool> frame_pool_;
    ComPtr<wgc::IGraphicsCaptureSession> session_;
    EventRegistrationToken frame_token_ = {};

    ComPtr<ID3D11Texture2D> staging_;
    UINT staging_w_ = 0;
    UINT staging_h_ = 0;
};

LumaWebViewCapture::LumaWebViewCapture() : impl_(new LumaWebViewCaptureImpl(this)) {}

LumaWebViewCapture::~LumaWebViewCapture() { delete impl_; }

bool
LumaWebViewCapture::start(unsigned int width, unsigned int height)
{
    return impl_->start(width, height);
}

IUnknown *
LumaWebViewCapture::root_visual() const
{
    return impl_->root_visual();
}

void
LumaWebViewCapture::resize(unsigned int width, unsigned int height)
{
    impl_->resize(width, height);
}

void
LumaWebViewCapture::commit()
{
    impl_->commit();
}

void
LumaWebViewCapture::stop()
{
    impl_->stop();
}
