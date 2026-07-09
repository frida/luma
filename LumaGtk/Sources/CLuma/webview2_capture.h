#ifndef LUMA_WEBVIEW2_CAPTURE_H
#define LUMA_WEBVIEW2_CAPTURE_H

#include <cstdint>
#include <functional>

struct IUnknown;

// Renders a WebView2 composition visual off-screen and delivers its pixels as
// CPU BGRA buffers via Windows.Graphics.Capture, so the caller (GTK) can draw
// the editor as ordinary widget content instead of compositing a native
// surface (which would occlude, or be occluded by, GTK overlays).
//
// The webview's ICoreWebView2CompositionController::put_RootVisualTarget is set
// to root_visual(), a Windows.UI.Composition container visual. That visual tree
// is captured directly with GraphicsCaptureItem::CreateFromVisual — no window is
// involved, so there is nothing on screen to occlude and no dependency on DWM
// compositing a hidden window.
class LumaWebViewCaptureImpl;

class LumaWebViewCapture {
public:
    LumaWebViewCapture();
    ~LumaWebViewCapture();

    LumaWebViewCapture(const LumaWebViewCapture &) = delete;
    LumaWebViewCapture &operator=(const LumaWebViewCapture &) = delete;

    // Creates the D3D/DComp/capture pipeline. width/height in device pixels.
    bool start(unsigned int width, unsigned int height);

    // The IDCompositionVisual for put_RootVisualTarget. Valid after start().
    IUnknown *root_visual() const;

    // Resize the off-screen host window and the capture frame pool.
    void resize(unsigned int width, unsigned int height);

    // Commit the DirectComposition device (call on the thread that created it) so
    // WebView2's latest render is presented and becomes capturable.
    void commit();

    void stop();

    // Invoked on a WinRT threadpool thread with a premultiplied BGRA8 buffer
    // valid only for the duration of the call; the callee must copy out.
    std::function<void(const uint8_t *bgra, int width, int height, int stride)> on_frame;

private:
    LumaWebViewCaptureImpl *impl_;
};

#endif
