#include "include/CWebKit.h"

#include <webkit/webkit.h>
#include <jsc/jsc.h>
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
