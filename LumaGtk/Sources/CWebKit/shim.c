#include "include/CWebKit.h"

#include <webkit/webkit.h>
#include <jsc/jsc.h>
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>

struct LumaMonacoView {
    WebKitWebView *web_view;
    LumaMonacoLoadFinishedCallback load_callback;
    void *load_user_data;
    LumaMonacoTextCallback text_callback;
    void *text_user_data;
};

static void
on_load_changed(WebKitWebView *view, WebKitLoadEvent event, gpointer user_data)
{
    (void)view;
    if (event != WEBKIT_LOAD_FINISHED) {
        return;
    }
    LumaMonacoView *self = (LumaMonacoView *)user_data;
    if (self->load_callback) {
        self->load_callback(self, self->load_user_data);
    }
}

static void
on_text_received(WebKitUserContentManager *manager,
                 JSCValue *value,
                 gpointer user_data)
{
    (void)manager;
    LumaMonacoView *self = (LumaMonacoView *)user_data;
    if (!jsc_value_is_string(value) || !self->text_callback) {
        return;
    }
    char *str = jsc_value_to_string(value);
    if (str) {
        self->text_callback(str, self->text_user_data);
        g_free(str);
    }
}

LumaMonacoView *
luma_monaco_view_new(void)
{
    LumaMonacoView *self = g_new0(LumaMonacoView, 1);
    self->web_view = WEBKIT_WEB_VIEW(webkit_web_view_new());

    WebKitSettings *settings = webkit_web_view_get_settings(self->web_view);
    webkit_settings_set_enable_developer_extras(settings, TRUE);
    webkit_settings_set_enable_write_console_messages_to_stdout(settings, TRUE);

    g_signal_connect(self->web_view, "load-changed", G_CALLBACK(on_load_changed), self);
    return self;
}

void *
luma_monaco_view_widget(LumaMonacoView *view)
{
    return (void *)view->web_view;
}

void
luma_monaco_view_load_uri(LumaMonacoView *view, const char *uri)
{
    webkit_web_view_load_uri(view->web_view, uri);
}

void
luma_monaco_view_evaluate(LumaMonacoView *view, const char *script_utf8)
{
    webkit_web_view_evaluate_javascript(view->web_view,
                                         script_utf8,
                                         -1,
                                         NULL,
                                         NULL,
                                         NULL,
                                         NULL,
                                         NULL);
}

void
luma_monaco_view_set_load_finished(LumaMonacoView *view,
                                    LumaMonacoLoadFinishedCallback callback,
                                    void *user_data)
{
    view->load_callback = callback;
    view->load_user_data = user_data;
}

void
luma_monaco_view_set_text_handler(LumaMonacoView *view,
                                   LumaMonacoTextCallback callback,
                                   void *user_data)
{
    view->text_callback = callback;
    view->text_user_data = user_data;

    WebKitUserContentManager *manager = webkit_web_view_get_user_content_manager(view->web_view);
    g_signal_connect(manager,
                      "script-message-received::updateText",
                      G_CALLBACK(on_text_received),
                      view);
    webkit_user_content_manager_register_script_message_handler(manager, "updateText", NULL);
}

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
