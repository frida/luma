#include "include/CLuma.h"

#include <gtk/gtk.h>
#include <gdk/win32/gdkwin32.h>
#include <windows.h>
#include <dwmapi.h>

// Windows 11 DWM attribute and values (missing from older SDKs).
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_ROUND
#define DWMWCP_ROUND 2
#endif

static HWND
hwnd_for_widget(GtkWidget *widget)
{
    GtkNative *native = gtk_widget_get_native(widget);
    if (native == nullptr) {
        return nullptr;
    }
    GdkSurface *surface = gtk_native_get_surface(native);
    if (surface == nullptr || !GDK_IS_WIN32_SURFACE(surface)) {
        return nullptr;
    }
    return reinterpret_cast<HWND>(
        gdk_win32_surface_get_handle(GDK_WIN32_SURFACE(surface)));
}

static void
apply_dwm_attributes(HWND hwnd)
{
    if (hwnd == nullptr) {
        return;
    }

    // DWMWCP_ROUND asks DWM to round the window's outer corners at
    // compositor level. No-op on Windows 10 — DwmSetWindowAttribute
    // just returns an error and the window stays rectangular, which
    // is the acceptable fallback.
    UINT corner_preference = DWMWCP_ROUND;
    DwmSetWindowAttribute(hwnd,
                          DWMWA_WINDOW_CORNER_PREFERENCE,
                          &corner_preference,
                          sizeof(corner_preference));
}

static void
on_window_realize(GtkWidget *widget, gpointer /*user_data*/)
{
    apply_dwm_attributes(hwnd_for_widget(widget));
}

extern "C" void
luma_prepare_window(void *window)
{
    if (window == nullptr) {
        return;
    }
    GtkWidget *widget = GTK_WIDGET(window);

    // GDK's win32 backend reports the DWM compositor as available,
    // so GTK doesn't auto-apply .solid-csd like it does on
    // X11-without-compositor. The result is a reserved (but unpainted)
    // shadow margin that renders as a solid black band on Windows.
    // Force solid decorations so GTK stops reserving the margin.
    gtk_widget_add_css_class(widget, "solid-csd");

    if (gtk_widget_get_realized(widget)) {
        apply_dwm_attributes(hwnd_for_widget(widget));
    } else {
        g_signal_connect(widget, "realize",
                         G_CALLBACK(on_window_realize),
                         nullptr);
    }
}
