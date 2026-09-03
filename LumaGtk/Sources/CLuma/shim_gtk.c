#include "include/CLuma.h"

#include <gtk/gtk.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <string.h>

// --- File menu / actions ----------------------------------------------------

typedef struct {
    LumaActionCallback callback;
    void *user_data;
} LumaActionCtx;

static void
on_action_activate(GSimpleAction *action,
                    GVariant *parameter,
                    gpointer user_data)
{
    (void)action;
    (void)parameter;
    LumaActionCtx *ctx = (LumaActionCtx *)user_data;
    ctx->callback(ctx->user_data);
}

static void
on_action_ctx_free(gpointer data, GClosure *closure)
{
    (void)closure;
    g_free(data);
}

void
luma_action_install(void *gobject_application,
                     const char *name,
                     LumaActionCallback callback,
                     void *user_data)
{
    GApplication *app = G_APPLICATION(gobject_application);
    GSimpleAction *action = g_simple_action_new(name, NULL);
    LumaActionCtx *ctx = g_new0(LumaActionCtx, 1);
    ctx->callback = callback;
    ctx->user_data = user_data;
    g_signal_connect_data(action,
                          "activate",
                          G_CALLBACK(on_action_activate),
                          ctx,
                          on_action_ctx_free,
                          0);
    g_action_map_add_action(G_ACTION_MAP(app), G_ACTION(action));
    g_object_unref(action);
}

void *
luma_menu_new(void)
{
    return g_menu_new();
}

void
luma_menu_append(void *menu, const char *label, const char *detailed_action)
{
    g_menu_append(G_MENU(menu), label, detailed_action);
}

void
luma_menu_append_submenu(void *menu, const char *label, void *submenu)
{
    g_menu_append_submenu(G_MENU(menu), label, G_MENU_MODEL(submenu));
}

void
luma_menu_append_section(void *menu, void *section)
{
    g_menu_append_section(G_MENU(menu), NULL, G_MENU_MODEL(section));
}

void
luma_menu_remove_all(void *menu)
{
    g_menu_remove_all(G_MENU(menu));
}

void
luma_menu_unref(void *menu)
{
    g_object_unref(menu);
}

void
luma_app_set_accels(void *gobject_application,
                     const char *detailed_action,
                     const char *primary_accel)
{
    GtkApplication *app = GTK_APPLICATION(gobject_application);
    const char *accels[2] = { primary_accel, NULL };
    gtk_application_set_accels_for_action(app, detailed_action, accels);
}

void
luma_menu_button_set_menu(void *menu_button, void *menu_model)
{
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(menu_button),
                                    G_MENU_MODEL(menu_model));
}

// File dialogs.

typedef struct {
    LumaPathCallback callback;
    void *user_data;
} LumaPathCtx;

static void
on_open_finished(GObject *source, GAsyncResult *result, gpointer user_data)
{
    LumaPathCtx *ctx = (LumaPathCtx *)user_data;
    GError *error = NULL;
    GFile *file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, &error);
    if (file != NULL) {
        char *path = g_file_get_path(file);
        ctx->callback(path, ctx->user_data);
        g_free(path);
        g_object_unref(file);
    } else {
        ctx->callback(NULL, ctx->user_data);
        if (error != NULL) {
            g_error_free(error);
        }
    }
    g_free(ctx);
}

static void
on_save_finished(GObject *source, GAsyncResult *result, gpointer user_data)
{
    LumaPathCtx *ctx = (LumaPathCtx *)user_data;
    GError *error = NULL;
    GFile *file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    if (file != NULL) {
        char *path = g_file_get_path(file);
        ctx->callback(path, ctx->user_data);
        g_free(path);
        g_object_unref(file);
    } else {
        ctx->callback(NULL, ctx->user_data);
        if (error != NULL) {
            g_error_free(error);
        }
    }
    g_free(ctx);
}

static void
on_select_folder_finished(GObject *source, GAsyncResult *result, gpointer user_data)
{
    LumaPathCtx *ctx = (LumaPathCtx *)user_data;
    GError *error = NULL;
    GFile *file = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(source), result, &error);
    if (file != NULL) {
        char *path = g_file_get_path(file);
        ctx->callback(path, ctx->user_data);
        g_free(path);
        g_object_unref(file);
    } else {
        ctx->callback(NULL, ctx->user_data);
        if (error != NULL) {
            g_error_free(error);
        }
    }
    g_free(ctx);
}

void
luma_file_dialog_open(void *parent_window,
                      const char *title,
                      LumaPathCallback callback,
                      void *user_data)
{
    GtkFileDialog *dialog = gtk_file_dialog_new();
    if (title != NULL) {
        gtk_file_dialog_set_title(dialog, title);
    }
    gtk_file_dialog_set_modal(dialog, TRUE);

    LumaPathCtx *ctx = g_new0(LumaPathCtx, 1);
    ctx->callback = callback;
    ctx->user_data = user_data;

    gtk_file_dialog_open(dialog, GTK_WINDOW(parent_window), NULL, on_open_finished, ctx);
    g_object_unref(dialog);
}

void
luma_file_dialog_save(void *parent_window,
                      const char *title,
                      const char *initial_name,
                      LumaPathCallback callback,
                      void *user_data)
{
    GtkFileDialog *dialog = gtk_file_dialog_new();
    if (title != NULL) {
        gtk_file_dialog_set_title(dialog, title);
    }
    if (initial_name != NULL) {
        gtk_file_dialog_set_initial_name(dialog, initial_name);
    }
    gtk_file_dialog_set_modal(dialog, TRUE);

    LumaPathCtx *ctx = g_new0(LumaPathCtx, 1);
    ctx->callback = callback;
    ctx->user_data = user_data;

    gtk_file_dialog_save(dialog, GTK_WINDOW(parent_window), NULL, on_save_finished, ctx);
    g_object_unref(dialog);
}

void
luma_folder_dialog_select(void *parent_window,
                          const char *title,
                          LumaPathCallback callback,
                          void *user_data)
{
    GtkFileDialog *dialog = gtk_file_dialog_new();
    if (title != NULL) {
        gtk_file_dialog_set_title(dialog, title);
    }
    gtk_file_dialog_set_modal(dialog, TRUE);

    LumaPathCtx *ctx = g_new0(LumaPathCtx, 1);
    ctx->callback = callback;
    ctx->user_data = user_data;

    gtk_file_dialog_select_folder(dialog, GTK_WINDOW(parent_window), NULL, on_select_folder_finished, ctx);
    g_object_unref(dialog);
}

typedef struct {
    LumaOpenFilesCallback callback;
    void *user_data;
} LumaOpenCtx;

static void
on_app_open(GApplication *app, GFile **files, int n_files, const char *hint, gpointer user_data)
{
    (void)app;
    (void)hint;
    LumaOpenCtx *ctx = (LumaOpenCtx *)user_data;
    for (int i = 0; i < n_files; i++) {
        char *path = g_file_get_path(files[i]);
        if (path) {
            ctx->callback(path, ctx->user_data);
            g_free(path);
        } else {
            char *uri = g_file_get_uri(files[i]);
            if (uri) {
                ctx->callback(uri, ctx->user_data);
                g_free(uri);
            }
        }
    }
}

void
luma_app_set_open_handler(void *gobject_application,
                           LumaOpenFilesCallback callback,
                           void *user_data)
{
    LumaOpenCtx *ctx = g_new0(LumaOpenCtx, 1);
    ctx->callback = callback;
    ctx->user_data = user_data;
    g_signal_connect(G_APPLICATION(gobject_application), "open", G_CALLBACK(on_app_open), ctx);
}

// --- Image normalization ----------------------------------------------------

static GdkPixbuf *
load_and_scale(const unsigned char *in_bytes, size_t in_size, int max_dimension)
{
    GInputStream *stream = g_memory_input_stream_new_from_data(in_bytes, (gssize)in_size, NULL);
    GdkPixbuf *pixbuf = gdk_pixbuf_new_from_stream(stream, NULL, NULL);
    g_object_unref(stream);
    if (!pixbuf) return NULL;

    int w = gdk_pixbuf_get_width(pixbuf);
    int h = gdk_pixbuf_get_height(pixbuf);
    int longest = w > h ? w : h;
    if (longest <= max_dimension) return pixbuf;

    double scale = (double)max_dimension / (double)longest;
    int nw = (int)(w * scale);
    int nh = (int)(h * scale);
    GdkPixbuf *scaled = gdk_pixbuf_scale_simple(pixbuf, nw, nh, GDK_INTERP_BILINEAR);
    g_object_unref(pixbuf);
    return scaled;
}

bool
luma_image_normalize(const unsigned char *in_bytes,
                      size_t in_size,
                      int max_dimension,
                      unsigned char **out_bytes,
                      size_t *out_size,
                      int *out_width,
                      int *out_height)
{
    GdkPixbuf *pixbuf = load_and_scale(in_bytes, in_size, max_dimension);
    if (!pixbuf) return false;

    gchar *buf = NULL;
    gsize buf_len = 0;
    gboolean ok = gdk_pixbuf_save_to_buffer(
        pixbuf, &buf, &buf_len, "jpeg", NULL, "quality", "85", NULL);
    if (ok) {
        if (out_width) *out_width = gdk_pixbuf_get_width(pixbuf);
        if (out_height) *out_height = gdk_pixbuf_get_height(pixbuf);
    }
    g_object_unref(pixbuf);
    if (!ok) return false;

    *out_bytes = (unsigned char *)buf;
    *out_size = (size_t)buf_len;
    return true;
}

bool
luma_image_normalize_to_png(const unsigned char *in_bytes,
                             size_t in_size,
                             int max_dimension,
                             unsigned char **out_bytes,
                             size_t *out_size,
                             int *out_width,
                             int *out_height)
{
    GdkPixbuf *pixbuf = load_and_scale(in_bytes, in_size, max_dimension);
    if (!pixbuf) return false;

    gchar *buf = NULL;
    gsize buf_len = 0;
    gboolean ok = gdk_pixbuf_save_to_buffer(
        pixbuf, &buf, &buf_len, "png", NULL, NULL);
    if (ok) {
        if (out_width) *out_width = gdk_pixbuf_get_width(pixbuf);
        if (out_height) *out_height = gdk_pixbuf_get_height(pixbuf);
    }
    g_object_unref(pixbuf);
    if (!ok) return false;

    *out_bytes = (unsigned char *)buf;
    *out_size = (size_t)buf_len;
    return true;
}

// --- Pointer capture --------------------------------------------------------

#if defined(_WIN32)

#include <windows.h>

bool
luma_pointer_location(double *x, double *y)
{
    POINT point;
    if (!GetCursorPos(&point)) return false;
    *x = point.x;
    *y = point.y;
    return true;
}

void
luma_pointer_place(double x, double y)
{
    SetCursorPos((int)(x + 0.5), (int)(y + 0.5));
}

#elif defined(__APPLE__)

#include <CoreGraphics/CoreGraphics.h>

bool
luma_pointer_location(double *x, double *y)
{
    CGEventRef event = CGEventCreate(NULL);
    CGPoint point = CGEventGetLocation(event);
    CFRelease(event);
    *x = point.x;
    *y = point.y;
    return true;
}

void
luma_pointer_place(double x, double y)
{
    CGWarpMouseCursorPosition(CGPointMake(x, y));
    CGAssociateMouseAndMouseCursorPosition(true);
}

#else

#ifdef GDK_WINDOWING_X11
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#endif

bool
luma_pointer_location(double *x, double *y)
{
#ifdef GDK_WINDOWING_X11
    GdkDisplay *display = gdk_display_get_default();
    if (GDK_IS_X11_DISPLAY(display)) {
        Display *xdisplay = gdk_x11_display_get_xdisplay(display);
        Window root_return, child_return;
        int root_x, root_y, win_x, win_y;
        unsigned int mask;
        if (XQueryPointer(xdisplay, DefaultRootWindow(xdisplay),
                          &root_return, &child_return,
                          &root_x, &root_y, &win_x, &win_y, &mask)) {
            *x = root_x;
            *y = root_y;
            return true;
        }
    }
#endif
    return false;
}

void
luma_pointer_place(double x, double y)
{
#ifdef GDK_WINDOWING_X11
    GdkDisplay *display = gdk_display_get_default();
    if (GDK_IS_X11_DISPLAY(display)) {
        Display *xdisplay = gdk_x11_display_get_xdisplay(display);
        XWarpPointer(xdisplay, None, DefaultRootWindow(xdisplay),
                     0, 0, 0, 0, (int)(x + 0.5), (int)(y + 0.5));
        XFlush(xdisplay);
    }
#endif
}

#endif

void
luma_widget_set_cursor_name(void *widget, const char *name)
{
    gtk_widget_set_cursor_from_name(GTK_WIDGET(widget), name);
}
